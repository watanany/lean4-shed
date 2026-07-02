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
-/
elab "dbt_check " path:str : command => do
  let proj ← match ← loadProject path.getString with
    | .ok p => pure p
    | .error e => throwError "dbt_check: {path.getString} の取り込みに失敗: {e}"
  let violations := runRules defaultRules proj
  if violations.isEmpty then
    logInfo s!"dbt_check: モデル {proj.models.size} 件、レイヤー規約違反なし"
  else
    throwError "dbt_check: レイヤー規約違反 {violations.size} 件:\n{String.intercalate "\n" violations.toList}"

end Shed.Sys.Dbt
