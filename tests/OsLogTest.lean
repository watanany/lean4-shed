import Shed.Sys.Os
import Shed.Sys.Log
import Shed.Sys.Py

/-! # Shed.Sys.Os / Shed.Sys.Log のテスト -/

open Shed.Sys

def check (label : String) (cond : Bool) : IO Unit := do
  if cond then
    IO.println s!"ok: {label}"
  else
    throw <| IO.userError s!"NG: {label}"

def main : IO Unit := do
  -- glob: 実リポジトリ相手
  let leans ← Os.glob "Shed/**/*.lean"
  check "glob: Shed/**/*.lean が複数見つかる" (leans.size ≥ 8)
  check "glob: Http.lean を含む"
    (leans.any (·.toString.endsWith "Shed/Sys/Http.lean"))
  let sqls ← Os.glob "models/*.sql" (root := "examples/dbt")
  check "glob: root 指定と単段の *" (sqls.size == 3)
  let none ← Os.glob "**/*.xyz"
  check "glob: マッチなしは空" (none.isEmpty)

  -- 隠しディレクトリの除外(.lake のビルド生成物を拾わない)
  let allLeans ← Os.glob "**/*.lean"
  check "glob: .lake / .git を歩かない"
    (!allLeans.isEmpty &&
      allLeans.all (fun f =>
        !(f.toString.splitOn "/").any (fun s => s.startsWith "." && s != ".")))
  let workflows ← Os.glob ".github/workflows/*.yml" (includeHidden := true)
  check "glob: includeHidden で隠しディレクトリも対象になる" (workflows.size == 1)

  -- Glob: Python の fnmatch をオラクルにした照合の突き合わせ
  let cases : Array (String × String) := #[
    ("*.lean", "Shed.lean"), ("*.lean", "Shed"), ("st?_*.sql", "stg_orders.sql"),
    ("data_[0-9].csv", "data_3.csv"), ("data_[0-9].csv", "data_x.csv"),
    ("[!0-9]*", "x1"), ("[!0-9]*", "1x"), ("a[-z]b", "a-b"), ("a[-z]b", "azb"),
    ("x[]]y", "x]y"), ("a[b", "a[b"), ("[A-Fa-f]0", "e0"), ("[A-Fa-f]0", "g0")]
  let oracle : Array Bool ← Py.call
    "[__import__('fnmatch').fnmatchcase(t, p) for p, t in data]" cases
  let ours := cases.map fun (p, t) => Shed.Pure.Glob.matchPath p t
  check "glob: 13 ケースで Python fnmatch と一致" (ours == oracle)

  -- Log: しきい値(既定 info)で debug が抑制されること
  Log.debug "これは出ないはず"
  Log.info "これは出るはず(stderr)"
  check "Log: レベル API が呼べる" true

  IO.println "Os / Log テスト全件成功"
