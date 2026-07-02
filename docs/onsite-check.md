# 社内 dbt プロジェクトの構造検証(持ち込み手順)

manifest.json は機密(テーブル名・カラム名・コンパイル済み SQL を含む)なので
**社外に持ち出さない**。代わりに shed の検証器を社内環境に持ち込み、
検証はすべて社内で完結させる。社外に出るのは違反の有無という判定だけ。

この手順は社内側の Claude Code 等のエージェントに渡す想定で書いてある。

## 手順

1. Lean 4 環境が無ければ elan を導入する
   (`curl https://elan.lean-lang.org/elan-init.sh -sSf | sh`)。
   toolchain は本リポジトリの `lean-toolchain` が解決する
2. 本リポジトリを取得して `lake build`。
   GitHub に出られない環境では、`Shed/Pure/Dbt.lean` と `Shed/Sys/Dbt.lean` の
   2 ファイルだけを新規 lake プロジェクトに写せば動く(依存は Lean 標準のみ)
3. 対象の dbt プロジェクトで `dbt parse` を実行し `target/manifest.json` を用意する
   (手元の dbt バージョンで生成し直すのが安全)
4. 次の 1 ファイル(例: `Check.lean`)を書いて `lake env lean --run Check.lean`:

   ```lean
   import Shed.Sys.Dbt

   -- コンパイルが通れば規約違反ゼロ。違反があれば日本語メッセージ付きで
   -- コンパイルエラーになる
   dbt_check "対象プロジェクト/target/manifest.json"

   def main : IO Unit := pure ()
   ```

5. 命名規約が既定(`stg_` 接頭辞)と違うプロジェクトでは述語を注入する。
   複数接頭辞なら `Conventions.ofPrefixes`、それで足りなければ任意の述語:

   ```lean
   import Shed.Sys.Dbt
   open Shed.Pure.Dbt

   def_dbt_project proj from "対象プロジェクト/target/manifest.json"

   def main : IO Unit := do
     -- 複数接頭辞
     let conv := Conventions.ofPrefixes #["stg_", "base_", "src_"]
     -- あるいは任意の述語(タグ・パス・正規表現など何でも):
     -- let conv : Conventions := { isStaging := fun n => n.tags.contains "staging" }
     let violations := runRules #[stagingOnlyFromRaw conv, martsNotOnRaw conv] proj
     for v in violations do IO.eprintln v
     if !violations.isEmpty then
       throw <| IO.userError s!"レイヤー規約違反 {violations.size} 件"
     IO.println s!"モデル {proj.models.size} 件、違反なし"
   ```

   カスタム規則を書くときは `Project.depType`(依存先の種別)と
   `NodeType.isRaw` が公開されているので再実装は不要。

6. 意図的な設計判断としての違反(例: mart 層によるマスタ source の直読み)は
   **受容宣言**で表明する。宣言ファイル(JSON、リポジトリにコミットする)を書き:

   ```json
   [{"model": "model.pkg.dim_area",
     "dep": "source.pkg.gsheet.master",
     "reason": "gsheet マスタは staging 化の対象外とする設計判断(2026-07)"}]
   ```

   ```lean
   dbt_check "対象プロジェクト/target/manifest.json" accepting "waivers.json"
   ```

   - `reason` は必須。理由を書けない例外は受容ではなく放置
   - **未使用の宣言もコンパイルエラー**になる(違反が解消されたら宣言も消す。
     受容リストの腐敗防止)
   - これで「コンパイルが通る = 未処理の違反ゼロ + 全例外が署名済み + 例外リストが実態と一致」になる

## 持ち帰ってよい情報(shed への還流)

機密を含まない「道具への苦情」だけを持ち帰る:

- manifest の取り込み成否と dbt のバージョン(dbt Fusion なら特に)。
  失敗時は `fromManifest?` のエラーメッセージ(構造の話のみ)
- 違反の件数と傾向(モデル名は不要)
- 規則・パーサが実態に合わなかった点、追加してほしい規約

manifest そのもの・テーブル名・カラム名・SQL は持ち帰らない。
