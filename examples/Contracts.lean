import Shed.Pure.Contract

/-!
# 契約の中核を使う例: dbt 向け成果物の生成

データ連携プロジェクト(dlt / dbt / Dagster)の staging 層を想定した
契約定義と、そこからの成果物生成。

実行: `lake env lean --run examples/Contracts.lean [出力ディレクトリ]`

生成物:
- `schema.yml` — dbt の schema tests(JSON は合法な YAML なのでそのまま読める)
- `<model>.schema.json` — 行単位の JSON Schema(dlt / API 境界の再検証用)

契約を変えたいときはこのファイルではなく契約定義を直し、生成し直す。
schema.yml を手で編集しない(大もとはこちら)。
-/

open Shed.Pure.Contract

/-- 顧客ステージング。 -/
def stgCustomers : Model := {
  name := "stg_customers"
  description := "顧客マスタの staging。ソースの生カラムを正規化したもの"
  columns := #[
    { name := "customer_id", type := .integer, unique := true,
      description := "顧客 ID(主キー)" },
    { name := "customer_name", type := .text },
    { name := "email", type := .text, nullable := true,
      description := "未登録の顧客がいるため NULL 許容" },
    { name := "created_at", type := .timestamp }
  ]
}

/-- 注文ステージング。 -/
def stgOrders : Model := {
  name := "stg_orders"
  description := "注文イベントの staging"
  columns := #[
    { name := "order_id", type := .integer, unique := true,
      description := "注文 ID(主キー)" },
    { name := "customer_id", type := .integer,
      description := "stg_customers への参照" },
    { name := "status", type := .text,
      accepted := #["placed", "shipped", "completed", "returned"],
      description := "注文状態。値を増やすときは契約を先に変える" },
    { name := "amount", type := .float,
      description := "注文金額" },
    { name := "ordered_at", type := .timestamp }
  ]
}

/-- このプロジェクトの全契約。 -/
def models : Array Model := #[stgCustomers, stgOrders]

def main (args : List String) : IO Unit := do
  let outDir : System.FilePath := args.headD "examples/out"
  IO.FS.createDirAll outDir
  -- dbt schema.yml(JSON as YAML)
  let schemaPath := outDir / "schema.yml"
  IO.FS.writeFile schemaPath ((dbtSchema models).pretty ++ "\n")
  IO.println s!"生成: {schemaPath}"
  -- モデルごとの JSON Schema
  for m in models do
    let path := outDir / s!"{m.name}.schema.json"
    IO.FS.writeFile path (m.toJsonSchema.pretty ++ "\n")
    IO.println s!"生成: {path}"
