import Shed.Sys.Dbt

/-!
# dbt manifest の取り込みと検証(使う例)

向き: **dbt(SQL)が大もと** → manifest.json → Lean。
dbt tests(行を見る)では書けない、プロジェクト構造への検証を行う。

前提: `examples/dbt` で dbt build 済み(manifest.json が存在すること)。

```sh
cd examples/dbt && python3 -m dbt.cli.main build --profiles-dir . && cd ../..
lake env lean --run examples/DbtChecks.lean
```
-/

open Shed.Pure.Dbt

-- コンパイル時に manifest を取り込んで定数化。
-- ここで manifest が壊れていたらコンパイルエラーになる
def_dbt_project proj from "examples/dbt/target/manifest.json"

-- コンパイル時にレイヤー規約を検査。違反があればビルドが落ちる
dbt_check "examples/dbt/target/manifest.json"

def check (label : String) (cond : Bool) : IO Unit := do
  if cond then
    IO.println s!"ok: {label}"
  else
    throw <| IO.userError s!"NG: {label}"

def main : IO Unit := do
  -- 取り込みの中身の確認
  check "モデルが 3 件(stg_customers / stg_orders / orders_by_customer)"
    (proj.models.size == 3)
  check "stg_orders のリネージが seed を指している"
    ((proj.models.find? (·.name == "stg_orders")).any
      (·.dependsOn.contains "seed.shed_contract_check.raw_orders"))
  check "mart がモデル経由で組まれている"
    ((proj.models.find? (·.name == "orders_by_customer")).any
      (·.dependsOn.contains "model.shed_contract_check.stg_orders"))

  -- レイヤー規約(コンパイル時にも検査済みだが、実行時 API の確認)
  check "レイヤー規約違反なし" (runRules defaultRules proj == #[])

  -- 契約(Lean 生成の schema.yml)と manifest の突き合わせ:
  -- 生成した列定義が dbt を往復して manifest に残っているか
  let schemaJson ← IO.FS.readFile "examples/out/schema.yml"
  let schema ← IO.ofExcept (Lean.Json.parse schemaJson)
  let contractModels := (schema.getObjValD "models").getArr?.toOption.getD #[]
  for cm in contractModels do
    let name := (cm.getObjValAs? String "name").toOption.getD "?"
    let cols := (cm.getObjValD "columns").getArr?.toOption.getD #[]
    let some node := proj.models.find? (·.name == name)
      | throw <| IO.userError s!"NG: 契約モデル {name} が manifest に無い"
    for c in cols do
      let colName := (c.getObjValAs? String "name").toOption.getD "?"
      check s!"契約列 {name}.{colName} が manifest に往復して残る"
        (node.columns.any (·.name == colName))

  IO.println "dbt manifest 検証: 全件成功"
