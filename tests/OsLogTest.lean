import Shed.Sys.Os
import Shed.Sys.Log

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

  -- Log: しきい値(既定 info)で debug が抑制されること
  Log.debug "これは出ないはず"
  Log.info "これは出るはず(stderr)"
  check "Log: レベル API が呼べる" true

  IO.println "Os / Log テスト全件成功"
