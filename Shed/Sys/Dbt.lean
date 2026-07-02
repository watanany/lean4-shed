import Lean
import Shed.Pure.Dbt

/-!
# Shed.Sys.Dbt — manifest のコンパイル時取り込み

dbt が吐いた manifest.json を**エラボレーション時**に読み込み、
Lean の定数・検証に変換するコマンド群。IO はコンパイル時に走る
(design.md §9 の「外部仕様からコンパイル時に型生成」の実地)。

- `def_dbt_project proj from "path/to/manifest.json"`
  — manifest を読み、検証済みの `Shed.Pure.Dbt.Project` 定数を定義する
- `dbt_check "path/to/manifest.json"`
  — 既定のレイヤー規約(`defaultRules`)をその場で実行し、
    違反があれば**コンパイルエラー**にする。`lake build` が契約ゲートになる

## 失敗モード(いずれもコンパイルエラーとして現れる)

- ファイルが無い / 読めない
- JSON としてパースできない / manifest の構造が想定と違う
- `dbt_check`: レイヤー規約違反

パスは実行時のカレントディレクトリ基準(lake はパッケージルートで走る)。
-/

namespace Shed.Sys.Dbt

open Lean Elab Command
open Shed.Pure.Dbt

/-- manifest を読んで `Project` にする(コンパイル時用の下層ヘルパ)。 -/
private def loadProject (path : String) : IO (Except String Project) := do
  let content ← IO.FS.readFile ⟨path⟩
  pure (Lean.Json.parse content >>= Project.fromManifest?)

/--
`def_dbt_project <名前> from "<manifest.json>"` —
manifest をコンパイル時に読み込み・検証し、`Project` 定数として埋め込む。
埋め込みは検証済み JSON(コンパクト化した Lean 側表現)の文字列経由で行う。
-/
elab "def_dbt_project " name:ident " from " path:str : command => do
  let proj ← match ← loadProject path.getString with
    | .ok p => pure p
    | .error e => throwError "def_dbt_project: {path.getString} の取り込みに失敗: {e}"
  let compact := (Lean.toJson proj).compress
  logInfo s!"def_dbt_project: {path.getString} からノード {proj.nodes.size} 件を取り込み"
  elabCommand (← `(def $name : Shed.Pure.Dbt.Project :=
    Shed.Pure.Dbt.Project.parse! $(quote compact)))

/--
`dbt_check "<manifest.json>"` — 既定のレイヤー規約をコンパイル時に実行し、
違反があればコンパイルを失敗させる。

`dbt_check "<manifest.json>" accepting "<waivers.json>"` — 受容宣言
(`Waiver` の JSON 配列。`model` / `dep` / `reason` が必須)を適用した上で
検査する。残った違反と**未使用の宣言**の両方がコンパイルエラーになる。
-/
private def checkImpl (path : String) (waiversPath : Option String) :
    CommandElabM Unit := do
  let proj ← match ← loadProject path with
    | .ok p => pure p
    | .error e => throwError "dbt_check: {path} の取り込みに失敗: {e}"
  let waivers : Array Waiver ← match waiversPath with
    | none => pure #[]
    | some wp =>
      let content ← IO.FS.readFile ⟨wp⟩
      match Lean.Json.parse content >>= Lean.fromJson? with
      | .ok ws => pure ws
      | .error e => throwError "dbt_check: 受容宣言 {wp} の読み込みに失敗: {e}"
  let problems := runRulesWith waivers defaultRules proj
  if problems.isEmpty then
    logInfo s!"dbt_check: モデル {proj.models.size} 件、レイヤー規約違反なし(受容宣言 {waivers.size} 件適用)"
  else
    throwError "dbt_check: 異常 {problems.size} 件:\n{String.intercalate "\n" problems.toList}"

elab "dbt_check " path:str : command =>
  checkImpl path.getString none

elab "dbt_check " path:str " accepting " waiversPath:str : command =>
  checkImpl path.getString (some waiversPath.getString)

end Shed.Sys.Dbt
