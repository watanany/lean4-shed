# shed

Lean 4 の個人用実験バッテリー。*Tools I needed twice.*

網羅が目的ではない。「Lean で日常の小道具が書ける」状態が目的。
規約は [CLAUDE.md](CLAUDE.md)、設計の経緯は [docs/design.md](docs/design.md)。

## 構成

- `Shed.Pure.*` — Lean のみで完結し検証可能なコード
- `Shed.Sys.*` — 外部依存(サブプロセス等)を伴うコード

外部接続の主経路はサブプロセス + JSON。FFI は原則使わない。

## ビルドとテスト

```sh
lake build
lake env lean --run tests/Smoke.lean   # python3 が必要
```

## 使用例

単発のサブプロセス呼び出し(`Shed.Sys.Subprocess`):

```lean
open Shed.Sys

-- stdin に書いて閉じ(EOF)、stdout を読み切る
let out ← callRaw { exe := "cat" } "hello\n"

-- JSON in / JSON out(exit code ≠ 0 はエラー)
let res ← callJsonRaw
  { exe := "python3", args := #["-c", "import sys, json; print(json.dumps(json.load(sys.stdin)))"] }
  (Lean.Json.mkObj [("n", (42 : Nat))])
```

常駐ワーカー(`Shed.Sys.Worker`)。行区切り JSON でやり取りし、
呼び出しは Mutex で直列化される:

```lean
withWorker { exe := "python3", args := #["-c", workerPy] } fun w => do
  let res ← w.callJson (Lean.Json.mkObj [("id", (1 : Nat))])
  ...
```

ワーカー側(Python)は 1 行読むごとに 1 行返し、**必ず flush する**:

```python
import sys, json
for line in sys.stdin:
    req = json.loads(line)
    print(json.dumps({"echo": req}), flush=True)
```

## 開発環境

`lean-toolchain`(elan)で安定版最新に固定。通常は elan があれば何もしなくてよい。
elan の配布サーバーに到達できない隔離環境では `scripts/setup-lean-nix.py` を参照。
