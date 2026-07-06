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
  -- Py: 逃げ道(式評価 + 型の往復)
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

  -- Data: DuckDB を呼んで使う
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

    -- パラメータ付きクエリ(クォートを含む値が安全に往復する)
    let rows ← db.query "select ? as s, ? as n" #[Json.str "o'hara", Lean.toJson (7 : Nat)]
    check "query: パラメータのクォート安全な往復"
      (rows[0]!.getObjValD "s" == Json.str "o'hara" &&
       (rows[0]!.getObjValD "n").getNat?.toOption == some 7)
    let rows ← db.query "select count(*) as c from orders where status = ?"
      #[Json.str "placed"]
    check "query: パラメータでの絞り込み"
      ((rows[0]!.getObjValD "c").getNat?.toOption == some 2)

    -- DATE は文字列で返る(doc に明記した挙動の固定)
    let rows ← db.query "select date '2026-01-02' as d"
    check "query: DATE は文字列で返る"
      (rows[0]!.getObjValD "d" == Json.str "2026-01-02")

    -- SQL エラーは IO.userError
    let failed ← try
      discard <| db.query "select * from no_such_table"
      pure false
    catch e => pure (toString e |>.startsWith "Shed.Sys.Data: SQL エラー")
    check "query: SQL エラーはメッセージ付きで落ちる" failed

    -- insertRows: 一時ファイル経由の一括投入(名前で突き合わせ、クォート・日本語も安全)
    db.exec "create table bulk (id int, name text, note text)"
    let mkRow (id : Nat) (name note : String) : Json :=
      Json.mkObj [("id", Lean.toJson id), ("name", Json.str name), ("note", Json.str note)]
    -- キー順がテーブル定義と違っても by name で入る
    let shuffled := Json.mkObj
      [("note", Json.str "順不同"), ("id", Lean.toJson (3 : Nat)), ("name", Json.str "c")]
    db.insertRows "bulk" #[mkRow 1 "o'hara" "引用符", mkRow 2 "眞鍋" "日本語", shuffled]
    let counts ← db.query "select count(*)::int as c from bulk"
    check "insertRows: 3 行入る" ((counts[0]!.getObjValD "c").getNat?.toOption == some 3)
    let rows ← db.query "select name from bulk where id = ?" #[Lean.toJson (1 : Nat)]
    check "insertRows: クォートを含む値が往復する"
      (rows[0]!.getObjValD "name" == Json.str "o'hara")
    let rows ← db.query "select name, note from bulk where id = 3"
    check "insertRows: キー順不同でも by name で正しい列に入る"
      (rows[0]!.getObjValD "name" == Json.str "c" &&
       rows[0]!.getObjValD "note" == Json.str "順不同")
    -- 空配列は no-op
    db.insertRows "bulk" #[]
    let counts ← db.query "select count(*)::int as c from bulk"
    check "insertRows: 空配列は no-op" ((counts[0]!.getObjValD "c").getNat?.toOption == some 3)

    -- テーブル名の " はエスケープされる(識別子を閉じて SQL を注入できない)
    db.exec "create table \"we\"\"ird\" (id int)"
    db.insertRows "we\"ird" #[Json.mkObj [("id", Lean.toJson (1 : Nat))]]
    let counts ← db.query "select count(*)::int as c from \"we\"\"ird\""
    check "insertRows: \" を含むテーブル名も安全" ((counts[0]!.getObjValD "c").getNat?.toOption == some 1)

    -- タイムアウト: 重いクエリは打ち切られ、その Duck は以後使えない(doc の主張を固定)
    -- ※ withDuck の最後に置く(ワーカーが kill されるため)
    let timedOut ← try
      discard <| db.query
        "select max(a.range * b.range) from range(1000000) a, range(100000) b"
        #[] (timeoutSec := 1)
      pure false
    catch _ => pure true
    check "query: タイムアウトで打ち切られる" timedOut
    let deadAfter ← try
      discard <| db.query "select 1"
      pure false
    catch _ => pure true
    check "query: タイムアウト後の Duck は使えない" deadAfter

  -- Py: タイムアウト(式が返らない場合も既定有界の範囲で打ち切られる)
  let pyTimedOut ← try
    discard <| Py.callJson "__import__('time').sleep(30)" (Json.mkObj []) (timeoutSec := 1)
    pure false
  catch _ => pure true
  check "Py.callJson: タイムアウトは IO.userError" pyTimedOut

  IO.println "Data / Py テスト全件成功"
