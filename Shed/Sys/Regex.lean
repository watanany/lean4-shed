import Shed.Sys.Worker

/-!
# Shed.Sys.Regex — PCRE 級の正規表現(エンジンを呼んで使う)

Python の `re` を常駐ワーカーとして呼んで使う。再実装ではなくエンジンを
呼んで使うので、**先読み・後読み・後方参照・名前付きグループを含む全機能が
最初から使える**(規約「使うと決まっている基本部品は一度で仕上げる」を
満たした例。エンジン自身が答え合わせの基準になるので、意味のずれが原理的に
起きない)。

```
withRe fun re => do
  let ok ← re.test r"\d{4}-\d{2}-\d{2}" "2026-07-02"
  let m ← re.find? r"(?P<user>\w+)@(\w+)" "mail: taro@example"
  let s ← re.replace r"(\w+)\s+\1" "重複 重複 を畳む" "\\1"
```

- パターンはワーカー側でコンパイルキャッシュされる(同一パターンの反復は速い)
- フラグは `Flags`(ignoreCase / multiline / dotAll / verbose)で注入
- `Match.start` / `stop` は**コードポイント**単位(Python 側の数え方)

## 失敗モード

- パターンが不正 → Python の位置情報つきエラーメッセージを含む `IO.userError`
- python3 が無い → ワーカー起動直後の呼び出しが失敗

## 有界性の注意

Python `re` はバックトラック型なので、病的なパターン(指数的後戻り)は
自力では戻らないが、ワーカー層のタイムアウト(既定 120 秒)が歯止めに
なる — 時間切れでワーカーごと kill され `IO.userError`(その `Re` は以後
使えない)。線形時間が必要な文脈(信頼できない入力・純粋文脈の規則述語)の
ための `Pure.Regex`(正規言語の部分集合、PikeVM)は実際に必要になった時に併設する。
-/

namespace Shed.Sys.Regex

open Lean (Json)

/-- 正規表現フラグ(Python `re` のフラグに対応)。 -/
structure Flags where
  /-- 大文字小文字を無視(`re.IGNORECASE`)-/
  ignoreCase : Bool := false
  /-- `^` `$` を各行に(`re.MULTILINE`)-/
  multiline : Bool := false
  /-- `.` を改行にもマッチ(`re.DOTALL`)-/
  dotAll : Bool := false
  /-- 空白とコメントを無視した冗長記法(`re.VERBOSE`)-/
  verbose : Bool := false
  deriving Repr, Inhabited

private def Flags.toPy (f : Flags) : Nat :=
  (if f.ignoreCase then 2 else 0) + (if f.multiline then 8 else 0)
    + (if f.dotAll then 16 else 0) + (if f.verbose then 64 else 0)

/-- 1 件のマッチ。位置はコードポイント単位。 -/
structure Match where
  /-- マッチした部分文字列全体 -/
  matched : String
  start : Nat
  stop : Nat
  /-- 番号つきグループ(`(...)`)。マッチしなかった腕は `none` -/
  groups : Array (Option String)
  /-- 名前付きグループ(`(?P<name>...)`)-/
  named : Array (String × Option String)
  deriving Repr, Inhabited

/-- 名前付きグループの値を引く(そのグループが無い・未マッチなら `none`)。 -/
def Match.named? (m : Match) (key : String) : Option String :=
  m.named.find? (·.1 == key) |>.bind (·.2)

-- example: 引ける / 未マッチ腕は none / 無い名前も none
#guard
  let m : Match := { matched := "a@b", start := 0, stop := 3,
                     groups := #[], named := #[("user", some "a"), ("opt", none)] }
  m.named? "user" == some "a" && m.named? "opt" == none && m.named? "zzz" == none

/-- Python ワーカー(行区切り JSON、パターンはコンパイルキャッシュ)。 -/
private def workerPy : String :=
  "import sys, json, re
cache = {}
def get(p, f):
    if (p, f) not in cache:
        cache[(p, f)] = re.compile(p, f)
    return cache[(p, f)]
def mjson(m):
    return {'match': m.group(0), 'start': m.start(), 'end': m.end(),
            'groups': list(m.groups()), 'named': m.groupdict()}
for line in sys.stdin:
    req = json.loads(line)
    try:
        pat = get(req['pattern'], req.get('flags', 0))
        op, text = req['op'], req.get('text', '')
        if op == 'test':
            out = pat.search(text) is not None
        elif op == 'find':
            m = pat.search(text)
            out = None if m is None else mjson(m)
        elif op == 'findall':
            out = [mjson(m) for m in pat.finditer(text)]
        elif op == 'sub':
            out = pat.sub(req['repl'], text, req.get('count', 0))
        elif op == 'split':
            out = [s if s is not None else '' for s in pat.split(text)]
        else:
            raise ValueError('unknown op: ' + op)
        print(json.dumps({'ok': out}, ensure_ascii=False), flush=True)
    except Exception as e:
        print(json.dumps({'error': str(e)}), flush=True)"

/-- 稼働中の正規表現エンジン。`withRe` で作る。 -/
structure Re where
  private worker : Worker

/-- エンジンを起動して `f` に渡し、終了時に必ず閉じるブラケット。 -/
def withRe (f : Re → IO α) : IO α :=
  withWorker { exe := "python3", args := #["-c", workerPy] } fun w =>
    f { worker := w }

private def request (re : Re) (op pattern text : String) (flags : Flags)
    (extra : List (String × Json) := []) : IO Json := do
  let res ← re.worker.callJson <| Json.mkObj <|
    [("op", Json.str op), ("pattern", Json.str pattern),
     ("text", Json.str text), ("flags", (flags.toPy : Nat))] ++ extra
  match res.getObjVal? "ok" with
  | .ok v => pure v
  | .error _ =>
    let msg := ((res.getObjValD "error").getStr?).toOption.getD res.compress
    throw <| IO.userError s!"Shed.Sys.Regex: {msg}"

private def matchFromJson (j : Json) : Except String Match := do
  let groups := ((j.getObjValD "groups").getArr?).toOption.getD #[]
    |>.map (·.getStr?.toOption)
  let named := match (j.getObjValD "named") with
    | .obj kvs => kvs.foldl (init := #[]) fun acc k v =>
        acc.push (k, v.getStr?.toOption)
    | _ => #[]
  pure { matched := ← j.getObjValAs? String "match"
         start := ← j.getObjValAs? Nat "start"
         stop := ← j.getObjValAs? Nat "end"
         groups, named }

/-- パターンが文字列のどこかにマッチするか。 -/
def Re.test (re : Re) (pattern text : String) (flags : Flags := {}) : IO Bool := do
  match (← request re "test" pattern text flags).getBool? with
  | .ok b => pure b
  | .error e => throw <| IO.userError s!"Shed.Sys.Regex.test: 応答形式が想定外: {e}"

/-- 最初のマッチ(なければ `none`)。 -/
def Re.find? (re : Re) (pattern text : String) (flags : Flags := {}) :
    IO (Option Match) := do
  let v ← request re "find" pattern text flags
  if v.isNull then pure none
  else match matchFromJson v with
    | .ok m => pure (some m)
    | .error e => throw <| IO.userError s!"Shed.Sys.Regex.find?: 応答形式が想定外: {e}"

/-- すべてのマッチ(重ならないもの)。 -/
def Re.findAll (re : Re) (pattern text : String) (flags : Flags := {}) :
    IO (Array Match) := do
  let v ← request re "findall" pattern text flags
  let arr := (v.getArr?).toOption.getD #[]
  arr.mapM fun j =>
    match matchFromJson j with
    | .ok m => pure m
    | .error e => throw <| IO.userError s!"Shed.Sys.Regex.findAll: 応答形式が想定外: {e}"

/-- 置換。`repl` では `\\1` や `\\g<name>` で捕捉を参照できる(Python `re.sub`)。
`count := 0` は全置換。 -/
def Re.replace (re : Re) (pattern text repl : String) (flags : Flags := {})
    (count : Nat := 0) : IO String := do
  let v ← request re "sub" pattern text flags
    [("repl", Json.str repl), ("count", (count : Nat))]
  match v.getStr? with
  | .ok s => pure s
  | .error e => throw <| IO.userError s!"Shed.Sys.Regex.replace: 応答形式が想定外: {e}"

/-- パターンで分割する。 -/
def Re.split (re : Re) (pattern text : String) (flags : Flags := {}) :
    IO (Array String) := do
  let v ← request re "split" pattern text flags
  let arr := (v.getArr?).toOption.getD #[]
  pure <| arr.map fun j => (j.getStr?).toOption.getD ""

end Shed.Sys.Regex
