import Lean.Data.Json

/-!
# Shed.Pure.Contract — データ契約の正本

データ契約(テーブルのスキーマ・制約)を Lean の型として一箇所で定義し、
各ツール向けの成果物を**生成**するためのカーネル。

- 正本はここ(Lean、機械検査される)。dbt の schema.yml や JSON Schema は生成物
- JSON は合法な YAML なので、`Lean.Json.pretty` の出力をそのまま `.yml` として
  dbt に読ませられる
- 網羅しない。dbt のテストは not_null / unique / accepted_values の
  標準三点のみ(自分が使う8割)。凝った制約が必要になったら実需駆動で足す

## 使い方の型

```
def stgOrders : Model := {
  name := "stg_orders"
  columns := #[
    { name := "order_id", type := .integer, unique := true },
    { name := "status", type := .text, accepted := #["placed", "shipped"] } ]
}
-- (dbtSchema #[stgOrders]).pretty を schema.yml に書き出す
```
-/

namespace Shed.Pure.Contract

open Lean (Json)

/-- 列の論理型。物理型名への変換は生成側(dbt / JSON Schema)が持つ。 -/
inductive ColumnType where
  | boolean
  | integer
  | float
  | text
  | date
  | timestamp
  /-- 構造を契約しない生 JSON 列。契約したくなったら独立した Model に昇格させる -/
  | json
  deriving Repr, BEq, Inhabited

/-- dbt(DuckDB 系)の `data_type` 名。 -/
def ColumnType.dbtName : ColumnType → String
  | .boolean => "boolean"
  | .integer => "bigint"
  | .float => "double"
  | .text => "varchar"
  | .date => "date"
  | .timestamp => "timestamp"
  | .json => "json"

/-- JSON Schema での型表現(`type` と、必要なら `format`)。 -/
def ColumnType.jsonSchemaFields : ColumnType → List (String × Json)
  | .boolean => [("type", Json.str "boolean")]
  | .integer => [("type", Json.str "integer")]
  | .float => [("type", Json.str "number")]
  | .text => [("type", Json.str "string")]
  | .date => [("type", Json.str "string"), ("format", Json.str "date")]
  | .timestamp => [("type", Json.str "string"), ("format", Json.str "date-time")]
  | .json => []

/-- 列の契約。NULL の既定は「許さない」(not_null テストが生成される)。
NULL を許すことこそ明示的な決定であるべき、という向き。 -/
structure Column where
  name : String
  type : ColumnType
  /-- NULL を許すか(既定: 許さない → dbt の not_null テストが生成される) -/
  nullable : Bool := false
  /-- 一意か(dbt の unique テストが生成される) -/
  unique : Bool := false
  /-- 許容値の列挙(text 列向け。dbt の accepted_values / JSON Schema の enum) -/
  accepted : Array String := #[]
  description : String := ""
  deriving Repr, Inhabited

/-- テーブル(dbt モデル)の契約。 -/
structure Model where
  name : String
  description : String := ""
  columns : Array Column
  deriving Repr, Inhabited

/-- 列から dbt のテスト列を導出する。 -/
def Column.dbtTests (c : Column) : Array Json := Id.run do
  let mut tests : Array Json := #[]
  if !c.nullable then
    tests := tests.push (Json.str "not_null")
  if c.unique then
    tests := tests.push (Json.str "unique")
  if !c.accepted.isEmpty then
    -- dbt 1.10+ の新形式: テスト引数は arguments 配下に置く
    tests := tests.push <| Json.mkObj
      [("accepted_values", Json.mkObj
        [("arguments", Json.mkObj
          [("values", Json.arr (c.accepted.map Json.str))])])]
  pure tests

/-- 空文字列の description は出力から落とす(生成物を汚さない)。 -/
private def descField (description : String) : List (String × Json) :=
  if description.isEmpty then [] else [("description", Json.str description)]

/-- 列の dbt schema.yml 表現。 -/
def Column.toDbt (c : Column) : Json :=
  let tests := c.dbtTests
  Json.mkObj <|
    [("name", Json.str c.name), ("data_type", Json.str c.type.dbtName)]
    ++ descField c.description
    ++ (if tests.isEmpty then [] else [("data_tests", Json.arr tests)])

/-- モデルの dbt schema.yml 表現。 -/
def Model.toDbt (m : Model) : Json :=
  Json.mkObj <|
    [("name", Json.str m.name)]
    ++ descField m.description
    ++ [("columns", Json.arr (m.columns.map Column.toDbt))]

/--
dbt の schema.yml 全体(`version: 2`)を生成する。
出力(`Json.pretty`)はそのまま `.yml` ファイルとして dbt が読める。
-/
def dbtSchema (models : Array Model) : Json :=
  Json.mkObj
    [("version", (2 : Nat)),
     ("models", Json.arr (models.map Model.toDbt))]

/-- 列の JSON Schema 表現(nullable は型の和、accepted は enum に落ちる)。 -/
def Column.toJsonSchema (c : Column) : Json :=
  let base := c.type.jsonSchemaFields
  let base :=
    match base with
    | ("type", t) :: rest =>
      if c.nullable then ("type", Json.arr #[t, Json.str "null"]) :: rest else base
    | _ => base
  let enum :=
    if c.accepted.isEmpty then []
    else
      let vals := c.accepted.map Json.str
      [("enum", Json.arr (if c.nullable then vals.push Json.null else vals))]
  Json.mkObj (base ++ enum ++ descField c.description)

/--
モデルから JSON Schema(draft 2020-12)を生成する。
1 行 = 1 オブジェクトとして検証する想定(dlt のスキーマ検証や
API 境界の再検証に使う)。
-/
def Model.toJsonSchema (m : Model) : Json :=
  Json.mkObj <|
    [("$schema", Json.str "https://json-schema.org/draft/2020-12/schema"),
     ("title", Json.str m.name)]
    ++ descField m.description
    ++ [("type", Json.str "object"),
        ("properties",
          Json.mkObj (m.columns.toList.map fun c => (c.name, c.toJsonSchema))),
        ("required",
          Json.arr ((m.columns.filter (!·.nullable)).map (Json.str ·.name))),
        ("additionalProperties", Json.bool false)]

-- 実行可能 example(コンパイル時に検証される)

-- example: 非 NULL 列の既定テストは not_null のみ
#guard Column.dbtTests { name := "id", type := .integer }
  == #[Json.str "not_null"]

-- example: unique 指定で not_null + unique
#guard Column.dbtTests { name := "id", type := .integer, unique := true }
  == #[Json.str "not_null", Json.str "unique"]

-- example: nullable にすると not_null が消える
#guard Column.dbtTests { name := "note", type := .text, nullable := true }
  == #[]

-- example: accepted_values は values の入れ子オブジェクトになる
#guard Column.dbtTests { name := "status", type := .text, accepted := #["a", "b"] }
  == #[Json.str "not_null",
       Json.mkObj [("accepted_values",
         Json.mkObj [("arguments",
           Json.mkObj [("values", Json.arr #[Json.str "a", Json.str "b"])])])]]

-- example: dbt schema.yml の最小形
-- (mkObj はキーを辞書順に直列化する。dbt/JSON Schema には順序の意味がないので無害)
#guard (dbtSchema #[{ name := "t", columns := #[{ name := "id", type := .integer }] }]).compress
  == "{\"models\":[{\"columns\":[{\"data_tests\":[\"not_null\"],\"data_type\":\"bigint\",\"name\":\"id\"}],\"name\":\"t\"}],\"version\":2}"

-- example: JSON Schema 側: 非 NULL 列は required に入る
#guard (Model.toJsonSchema { name := "t", columns :=
    #[{ name := "id", type := .integer },
      { name := "note", type := .text, nullable := true }] }).getObjValD "required"
  == Json.arr #[Json.str "id"]

end Shed.Pure.Contract
