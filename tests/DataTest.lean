import Shed.Sys.Data
import Shed.Sys.Py

/-!
# Shed.Sys.Data / Shed.Sys.Py のテスト

前提: `python3` と `pip install duckdb`。

実行: `lake env lean --run tests/DataTest.lean`
-/

open Shed.Sys Shed.Sys.Data
open Lean (Json)

def check (label : String) (cond : Bool) : IO Unit := do
  if cond then
    IO.println s!"ok: {label}"
  else
    throw <| IO.userError s!"NG: {label}"

/-- 型付きクエリの契約(行の形)。 -/
structure StatusCount where
  status : String
  n : Nat
  deriving Lean.FromJson, Repr

def main : IO Unit := do
  -- Py: 脱出ハッチ(式評価 + 型の往復)
  let sorted : Array Nat ← Py.call "sorted(set(data))" #[3, 1, 3, 2]
  check "Py.call: sorted(set(data))" (sorted == #[1, 2, 3])
  let s : String ← Py.call "data['a'] + data['b']"
    (Json.mkObj [("a", Json.str "こん"), ("b", Json.str "にちは")])
  check "Py.call: 文字列結合と日本語の往復" (s == "こんにちは")
  -- Py: 例外は IO.userError
  let failed ← try
    discard <| (Py.callJson "1/0" (Json.mkObj []))
    pure false
  catch _ => pure true
  check "Py.callJson: Python 例外はエラーになる" failed

  -- Data: DuckDB の運転
  withDuck fun db => do
    db.exec "create table orders (id int, status text, amount double)"
    db.exec "insert into orders values
      (1, 'placed', 100.5), (2, 'shipped', 200.0),
      (3, 'placed', 50.25), (4, 'returned', 10.0)"

    -- 素の JSON 行
    let rows ← db.query "select count(*) as c from orders"
    check "query: 件数" (rows.size == 1 &&
      ((rows[0]!.getObjValD "c").getNat?.toOption == some 4))

    -- 型付き(契約の再検証)
    let counts ← db.queryAs StatusCount
      "select status, count(*)::int as n from orders group by 1 order by n desc, status"
    check "queryAs: 集計が型に載る"
      (counts.map (fun c => (c.status, c.n)) == #[("placed", 2), ("returned", 1), ("shipped", 1)])

    -- CSV を直接読む(seeds を流用)
    let rows ← db.query
      "select count(*) as c from 'examples/dbt/seeds/raw_orders.csv'"
    check "query: CSV 直読み" ((rows[0]!.getObjValD "c").getNat?.toOption == some 4)

    -- SQL エラーは IO.userError
    let failed ← try
      discard <| db.query "select * from no_such_table"
      pure false
    catch e => pure (toString e |>.startsWith "Shed.Sys.Data: SQL エラー")
    check "query: SQL エラーはメッセージ付きで落ちる" failed

  IO.println "Data / Py テスト全件成功"
