import Shed.Sys.Subprocess

/-!
# Shed.Sys.Py — 型付き契約で Python を呼ぶ脱出ハッチ

どうしても Python が楽な処理は常に残る。それを敗北にせず、
**制御フローと型は Lean に留めたまま** Python 片を部品として呼ぶための層。

- 入力は `ToJson` で渡り、Python 側では変数 `data` に束縛される
- スニペットは `data` を使う **式**(expression)。その評価結果が
  JSON になって返り、`FromJson` で再検証される(契約の正本は Lean の型)
- スニペットは argv 経由で渡すためクォート地獄は無い

## 失敗モード

- python3 が無い / スニペットが例外を投げる / 結果が JSON にできない
  → 非ゼロ exit + stderr を含む `IO.userError`
- 結果が期待した型に合わない → `IO.userError`(`call` の FromJson 再検証)

## 有界性の注意

サブプロセス層のタイムアウト(既定 120 秒、`0` で無制限)を引き継ぐ。
-/

namespace Shed.Sys.Py

open Lean (Json)

/-- Python 側のブートストラップ。stdin の JSON を `data` に束縛し、
argv[1] の式を評価して JSON で返す。 -/
private def bootstrap : String :=
  "import sys, json
data = json.load(sys.stdin)
print(json.dumps(eval(sys.argv[1]), ensure_ascii=False, default=str))"

/--
Python の式 `snippet` を、`data` に `input` を束縛して評価する(JSON 版)。

```
let r ← Py.callJson "sorted(set(data))" (Lean.toJson #[3, 1, 3, 2])
-- r = [1, 2, 3]
```
-/
def callJson (snippet : String) (input : Json) (timeoutSec : Nat := 120) : IO Json :=
  callJsonRaw { exe := "python3", args := #["-c", bootstrap, snippet] } input timeoutSec

/-- 型付き版。入出力の契約は Lean の型(`ToJson` / `FromJson`)。 -/
def call [Lean.ToJson α] [Lean.FromJson β] (snippet : String) (input : α)
    (timeoutSec : Nat := 120) : IO β := do
  let json ← callJson snippet (Lean.toJson input) timeoutSec
  match Lean.fromJson? json with
  | .ok b => pure b
  | .error e =>
    throw <| IO.userError s!"Shed.Sys.Py.call: 応答が期待した型に合わない: {e}"

end Shed.Sys.Py
