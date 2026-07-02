import Lean.Data.Json

/-!
# Shed.Pure.Dbt — dbt manifest の型と検証規則

**正本の向きに注意**: `Shed.Pure.Contract` は「Lean が正本 → dbt を生成」だが、
こちらは逆向き — **dbt(SQL)が正本**であり、dbt が吐く manifest.json を
Lean に取り込んで、dbt tests では書けない検証(プロジェクト構造・レイヤー規約)
を行う。実プロジェクトでは dbt が既にチームの正本なので、Lean は
既存パイプラインに変更を求めない下流の検証・理解レイヤーとして導入できる。

- 取り込みは `Shed.Sys.Dbt` のコマンド(`def_dbt_project` / `dbt_check`)が行う
- ここは pure: manifest JSON の解釈と、規則(`Rule`)の定義のみ
- 規則は「グラフ全体を見る検証」— dbt の data test(行を見る)では
  表現できない層。dbt-project-evaluator 相当を素の Lean 関数として持つ

## 失敗モード

- manifest の構造が想定と違う → `fromManifest?` が `Except.error`
  (dbt のバージョン更新で壊れたらここで検出される)
-/

namespace Shed.Pure.Dbt

open Lean (Json ToJson FromJson toJson fromJson?)

/-- dbt ノードの種別。 -/
inductive NodeType where
  | model
  | seed
  | source
  | snapshot
  | test
  | other
  deriving Repr, BEq, Inhabited, Lean.ToJson, Lean.FromJson

def NodeType.ofString : String → NodeType
  | "model" => .model
  | "seed" => .seed
  | "source" => .source
  | "snapshot" => .snapshot
  | "test" => .test
  | _ => .other

/-- manifest 上の列情報。 -/
structure Column where
  name : String
  dataType : Option String := none
  description : String := ""
  deriving Repr, BEq, Inhabited, Lean.ToJson, Lean.FromJson

/-- manifest 上のノード(モデル・シード・ソース等)。 -/
structure Node where
  uniqueId : String
  name : String
  type : NodeType
  columns : Array Column := #[]
  /-- 依存先の uniqueId(dbt のリネージ) -/
  dependsOn : Array String := #[]
  tags : Array String := #[]
  deriving Repr, BEq, Inhabited, Lean.ToJson, Lean.FromJson

/-- dbt プロジェクト(manifest の Lean 側表現)。 -/
structure Project where
  nodes : Array Node
  deriving Repr, BEq, Inhabited, Lean.ToJson, Lean.FromJson

namespace Project

def models (p : Project) : Array Node :=
  p.nodes.filter (·.type == .model)

def find? (p : Project) (uniqueId : String) : Option Node :=
  p.nodes.find? (·.uniqueId == uniqueId)

end Project

/-- JSON オブジェクトを (キー, 値) の配列に潰す。 -/
private def objToArray (j : Json) : Array (String × Json) :=
  match j with
  | .obj kvs => kvs.foldl (init := #[]) fun acc k v => acc.push (k, v)
  | _ => #[]

private def strArray? (j : Json) : Array String :=
  match j with
  | .arr xs => xs.filterMap fun x => x.getStr?.toOption
  | _ => #[]

/-- manifest のノード 1 件を解釈する。 -/
private def nodeFromJson (uniqueId : String) (j : Json) : Except String Node := do
  let name ← j.getObjValAs? String "name"
  let type := (j.getObjValAs? String "resource_type").toOption.map NodeType.ofString
    |>.getD .other
  let columns := objToArray (j.getObjValD "columns") |>.map fun (colName, cj) =>
    { name := colName
      dataType := (cj.getObjValAs? String "data_type").toOption
      description := (cj.getObjValAs? String "description").toOption.getD "" }
  let dependsOn := strArray? ((j.getObjValD "depends_on").getObjValD "nodes")
  let tags := strArray? (j.getObjValD "tags")
  pure { uniqueId, name, type, columns, dependsOn, tags }

/--
dbt の manifest.json から `Project` を構築する。
`nodes`(モデル・シード等)と `sources` の両方を取り込む。
-/
def Project.fromManifest? (manifest : Json) : Except String Project := do
  let nodesJson ← manifest.getObjVal? "nodes"
  let mut nodes : Array Node := #[]
  for (uid, j) in objToArray nodesJson do
    nodes := nodes.push (← nodeFromJson uid j)
  -- sources は manifest の別キー。ソースとして取り込む
  for (uid, j) in objToArray (manifest.getObjValD "sources") do
    let name := (j.getObjValAs? String "name").toOption.getD uid
    nodes := nodes.push { uniqueId := uid, name, type := .source }
  pure { nodes }

/-- 三段命名: パース失敗で panic する版(取り込みコマンドが検証済みの入力に使う)。 -/
def Project.parse! (s : String) : Project :=
  match Json.parse s >>= fromJson? with
  | .ok p => p
  | .error e => panic! s!"Shed.Pure.Dbt.Project.parse!: {e}"

-- ## レイヤー規約

/-- 生データ(seed / source)か。 -/
def NodeType.isRaw : NodeType → Bool
  | .seed | .source => true
  | _ => false

/-- 依存先ノードの種別を引く(見つからなければ uniqueId の接頭辞で推定)。
カスタム規則を書くための公開 API。 -/
def Project.depType (p : Project) (uid : String) : NodeType :=
  match p.find? uid with
  | some n => n.type
  | none => NodeType.ofString (uid.splitOn "." |>.headD "")

/-- プロジェクト側の命名規約。shed は道具(dbt)は知ってよいが、
特定プロジェクトの規約は知らない — 規約は**述語**として注入する
(実プロジェクトの多層命名は単一接頭辞では表現できない、という
初回接触のフィードバックによる設計)。既定は dbt コミュニティの
慣習(`stg_` 接頭辞)。 -/
structure Conventions where
  /-- staging 層(生データの取り込み口)と見なすモデルの述語 -/
  isStaging : Node → Bool := fun n => n.name.startsWith "stg_"

/-- 複数接頭辞の簡便コンストラクタ:
`Conventions.ofPrefixes #["stg_", "base_", "src_"]` -/
def Conventions.ofPrefixes (staging : Array String) : Conventions :=
  { isStaging := fun n => staging.any (n.name.startsWith ·) }

/-- 規約違反。受容宣言(`Waiver`)との照合のため、モデルと依存先の
uniqueId を構造として持つ。 -/
structure Violation where
  /-- 違反したモデルの uniqueId -/
  modelId : String
  /-- 問題の依存先の uniqueId -/
  depId : String
  /-- 人間向けメッセージ -/
  message : String
  deriving Repr, BEq, Inhabited

/-- 検証規則。プロジェクト全体を見て違反の列を返す。 -/
def Rule := Project → Array Violation

/-- 規則: staging モデルは生データ(seed / source)だけに依存する。 -/
def stagingOnlyFromRaw (conv : Conventions := {}) : Rule := fun p =>
  p.models.filter conv.isStaging |>.flatMap fun m =>
    m.dependsOn.filterMap fun dep =>
      if (p.depType dep).isRaw then none
      else some { modelId := m.uniqueId, depId := dep,
                  message := s!"{m.name}: staging モデルが生データ以外({dep})に依存している" }

/-- 規則: staging 以外(mart 等)のモデルは生データに直接依存しない
(必ず staging を経由する)。 -/
def martsNotOnRaw (conv : Conventions := {}) : Rule := fun p =>
  p.models.filter (fun n => !conv.isStaging n) |>.flatMap fun m =>
    m.dependsOn.filterMap fun dep =>
      if (p.depType dep).isRaw then
        some { modelId := m.uniqueId, depId := dep,
               message := s!"{m.name}: mart モデルが生データ({dep})に直接依存している" }
      else none

/-- 既定の規則一式(既定の命名規約)。`dbt_check` コマンドはこれを実行する。
プロジェクト固有の規約は `stagingOnlyFromRaw (Conventions.ofPrefixes #[...])` や
`stagingOnlyFromRaw { isStaging := fun n => ... }` の形で注入する。 -/
def defaultRules : Array Rule := #[stagingOnlyFromRaw, martsNotOnRaw]

/-- 全規則を実行して違反メッセージを集める(受容宣言なしの素朴版)。 -/
def runRules (rules : Array Rule) (p : Project) : Array String :=
  rules.flatMap (· p) |>.map (·.message)

-- ## 受容宣言(意図的な規約違反の表明)

/--
受容済みの依存 = 意図的な設計判断としての規約違反。

例外は「見逃し」ではなく**署名済みの判断**として残す —
だから `reason` は必須。理由を書けない例外は受容ではなく放置である。
-/
structure Waiver where
  /-- 違反モデルの uniqueId(例: "model.pkg.dim_area")-/
  model : String
  /-- 受容する依存先の uniqueId(例: "source.pkg.gsheet.master")-/
  dep : String
  /-- なぜこの違反を受け入れるのか(必須)-/
  reason : String
  deriving Repr, BEq, Inhabited, Lean.ToJson, Lean.FromJson

/-- 違反の列に受容宣言を適用する。
返り値: (残った違反, 一度も使われなかった宣言)。

**未使用の宣言も異常**として返す — 違反が解消されたのに宣言が残るのは
受容リストの腐敗(実態と合っていない)なので、呼び出し側はエラーにすべき。 -/
def applyWaivers (waivers : Array Waiver) (violations : Array Violation) :
    Array Violation × Array Waiver :=
  let remaining := violations.filter fun v =>
    !waivers.any fun w => w.model == v.modelId && w.dep == v.depId
  let unused := waivers.filter fun w =>
    !violations.any fun v => w.model == v.modelId && w.dep == v.depId
  (remaining, unused)

/-- 全規則を実行し、受容宣言を適用した上で異常メッセージを集める。
残った違反と未使用の宣言の両方が異常。空なら健全。 -/
def runRulesWith (waivers : Array Waiver) (rules : Array Rule) (p : Project) :
    Array String :=
  let (remaining, unused) := applyWaivers waivers (rules.flatMap (· p))
  remaining.map (·.message)
    ++ unused.map fun w =>
      s!"未使用の受容宣言: {w.model} → {w.dep}(違反が存在しない。宣言を削除せよ)"

-- ## 実行可能 example

private def exampleProject : Project := {
  nodes := #[
    { uniqueId := "seed.pkg.raw_a", name := "raw_a", type := .seed },
    { uniqueId := "model.pkg.stg_a", name := "stg_a", type := .model,
      dependsOn := #["seed.pkg.raw_a"] },
    { uniqueId := "model.pkg.report_a", name := "report_a", type := .model,
      dependsOn := #["model.pkg.stg_a"] }
  ]
}

-- example: 規約に沿ったプロジェクトは違反ゼロ
#guard runRules defaultRules exampleProject == #[]

-- example: 命名規約は述語として注入できる(複数接頭辞はヘルパで)
#guard (Conventions.ofPrefixes #["stg_", "base_"]).isStaging
        { uniqueId := "model.pkg.base_a", name := "base_a", type := .model }
#guard !((Conventions.ofPrefixes #["stg_"]).isStaging
        { uniqueId := "model.pkg.dim_a", name := "dim_a", type := .model })

-- example: 任意の述語(タグ分類など)も注入できる
#guard (stagingOnlyFromRaw { isStaging := fun n => n.tags.contains "staging" }
        { nodes := #[
          { uniqueId := "model.pkg.a", name := "a", type := .model,
            dependsOn := #["model.pkg.b"], tags := #["staging"] }] }).size == 1

-- example: staging がモデルに依存すると stagingOnlyFromRaw が検出する
#guard (stagingOnlyFromRaw (conv := {}) { nodes := #[
    { uniqueId := "model.pkg.stg_b", name := "stg_b", type := .model,
      dependsOn := #["model.pkg.stg_a"] }] }).size == 1

-- example: mart が seed に直接依存すると martsNotOnRaw が検出する
#guard (martsNotOnRaw (conv := {}) { nodes := #[
    { uniqueId := "seed.pkg.raw_a", name := "raw_a", type := .seed },
    { uniqueId := "model.pkg.report_b", name := "report_b", type := .model,
      dependsOn := #["seed.pkg.raw_a"] }] }).size == 1

-- example: 受容宣言は該当する違反を消し、残りだけが異常になる
#guard
  let violations := #[
    { modelId := "model.pkg.dim_a", depId := "source.pkg.gsheet.m",
      message := "..." : Violation },
    { modelId := "model.pkg.dim_b", depId := "seed.pkg.pref",
      message := "..." : Violation }]
  let waivers := #[
    { model := "model.pkg.dim_a", dep := "source.pkg.gsheet.m",
      reason := "マスタの staging 化まで直読みを許容" : Waiver }]
  (applyWaivers waivers violations).1.map (·.modelId) == #["model.pkg.dim_b"]

-- example: 違反が解消されたのに残った宣言は「未使用」として検出される
#guard
  let waivers := #[
    { model := "model.pkg.dim_a", dep := "seed.pkg.x",
      reason := "撤去済みのはず" : Waiver }]
  (applyWaivers waivers #[]).2 == waivers

-- example: To/FromJson の roundtrip(取り込みコマンドの埋め込みが依存する性質)
#guard (match (fromJson? (toJson exampleProject) : Except String Project) with
        | .ok p => p == exampleProject
        | .error _ => false)

end Shed.Pure.Dbt
