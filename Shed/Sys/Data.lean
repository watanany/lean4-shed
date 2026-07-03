import Shed.Sys.Worker

/-!
# Shed.Sys.Data — DuckDB の運転(polars 相当の主経路)

DataFrame エンジンは移植せず**運転する**(CLAUDE.md)。
DuckDB を Python 常駐ワーカー(`duckdb` モジュール)として抱え、
SQL を送って行を JSON で受け取る。CSV / Parquet / JSON の読み書き・
結合・集計という日常の8割は SQL で Lean の型の内側に入る。

前提: `python3` と `pip install duckdb`。

```
withDuck (fun db => do
  db.exec "create table t as select * from 'data.csv'"
  let rows ← db.query "select status, count(*) as n from t group by 1"
  ...)
```

## 失敗モード

- python3 / duckdb モジュールが無い → ワーカー起動直後の呼び出しが失敗
- SQL エラー → DuckDB のエラーメッセージを含む `IO.userError`
- 行が期待した型に合わない(`queryAs`)→ `IO.userError`

## 型変換の注意

DuckDB の DATE / TIMESTAMP / DECIMAL は JSON 化の際に**文字列**になる
(ワーカーが `default=str` で直列化するため)。`queryAs` の契約型では
これらの列は `String` で受けること。数値で欲しいものは SQL 側で
`::int` / `::double` にキャストするのが確実。

## 有界性の注意

クエリごとのタイムアウトは既定 120 秒(`timeoutSec := 0` で無制限)。
時間切れはワーカーごと kill されるため、その `Duck` は以後使えない
(長時間かかる正当なクエリには明示的に大きな値を渡す)。
結果行数の上限は未実装 — 巨大な結果を select しない責任は
当面 SQL を書く側にある(必要になったら `limit` の既定注入等を検討)。

## 一括投入

行ごとの `exec "insert ..."` は 1 行 = 1 往復なので、まとまった行数は
`insertRows`(一時ファイル + `read_json`)を使う。ファイル読みは
DuckDB 側で行われる(エンジンの運転)。
-/

namespace Shed.Sys.Data

open Lean (Json)

/-- DuckDB ワーカー(行区切り JSON プロトコル)。 -/
private def workerPy : String :=
  "import sys, json, duckdb
con = duckdb.connect(sys.argv[1])
for line in sys.stdin:
    req = json.loads(line)
    try:
        cur = con.execute(req['sql'], req.get('params') or [])
        if cur.description is None:
            print(json.dumps({'ok': []}), flush=True)
        else:
            cols = [d[0] for d in cur.description]
            rows = [dict(zip(cols, r)) for r in cur.fetchall()]
            print(json.dumps({'ok': rows}, ensure_ascii=False, default=str), flush=True)
    except Exception as e:
        print(json.dumps({'error': str(e)}), flush=True)"

/-- 稼働中の DuckDB 接続。`withDuck` で作る。 -/
structure Duck where
  private worker : Worker

/--
DuckDB を開いて `f` に渡し、終了時に必ず閉じるブラケット。
`path` 省略時はインメモリ。
-/
def withDuck (f : Duck → IO α) (path : String := ":memory:") : IO α :=
  withWorker { exe := "python3", args := #["-c", workerPy, path] }
    fun w => f { worker := w }

/-- SQL を実行し、結果の行(1 行 = 1 JSON オブジェクト)を返す。

値は `?` プレースホルダと `params` で渡す(文字列連結でクォートしない):
```
db.query "select * from t where name = ? and n > ?"
  #[Lean.Json.str "o'hara", Lean.toJson 10]
```
-/
def Duck.query (db : Duck) (sql : String) (params : Array Json := #[])
    (timeoutSec : Nat := defaultTimeoutSec) : IO (Array Json) := do
  let res ← db.worker.callJson
    (Json.mkObj [("sql", Json.str sql), ("params", Json.arr params)])
    timeoutSec
  match res.getObjVal? "ok" with
  | .ok rows =>
    match rows.getArr? with
    | .ok arr => pure arr
    | .error e => throw <| IO.userError s!"Shed.Sys.Data: 応答形式が想定外: {e}"
  | .error _ =>
    let msg := ((res.getObjValD "error").getStr?).toOption.getD res.compress
    throw <| IO.userError s!"Shed.Sys.Data: SQL エラー: {msg}"

/-- 結果を返さない SQL(DDL / DML)を実行する。 -/
def Duck.exec (db : Duck) (sql : String) (params : Array Json := #[])
    (timeoutSec : Nat := defaultTimeoutSec) : IO Unit :=
  discard (db.query sql params timeoutSec)

/-- 型付きクエリ。各行を `FromJson` で再検証する(契約の正本は Lean の型)。 -/
def Duck.queryAs (β : Type) [Lean.FromJson β] (db : Duck) (sql : String)
    (params : Array Json := #[]) (timeoutSec : Nat := defaultTimeoutSec) : IO (Array β) := do
  let rows ← db.query sql params timeoutSec
  rows.mapM fun row =>
    match Lean.fromJson? row with
    | .ok b => pure b
    | .error e =>
      throw <| IO.userError s!"Shed.Sys.Data.queryAs: 行が期待した型に合わない: {e}\n行: {row.compress}"

/--
行の配列を一括投入する。一時ファイルに JSON で書き出し、DuckDB 側の
`read_json` に読ませて `insert into ... by name` する(1 行ずつの INSERT の
1 行 = 1 往復を避ける)。列はテーブル定義と**名前**で突き合わせるため、
行オブジェクトのキー順は問わない。

`table` は識別子として(`"` をエスケープした上で)埋め込む。テーブルは事前に
`exec "create table ..."` で作っておくこと。

```
db.insertRows "access_log" (rows.map Lean.toJson)
```
-/
def Duck.insertRows (db : Duck) (table : String) (rows : Array Json)
    (timeoutSec : Nat := defaultTimeoutSec) : IO Unit := do
  if rows.isEmpty then
    return
  IO.FS.withTempFile fun h path => do
    h.putStr (Json.arr rows).compress
    h.flush
    -- 識別子は `"` を二重化、パス(SQL 文字列リテラル)は `'` を二重化して埋める
    let ident := "\"" ++ table.replace "\"" "\"\"" ++ "\""
    let file := path.toString.replace "'" "''"
    db.exec s!"insert into {ident} by name select * from read_json('{file}', format = 'array')"
      #[] timeoutSec

end Shed.Sys.Data
