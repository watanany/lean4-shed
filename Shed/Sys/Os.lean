import Shed.Pure.Glob

/-!
# Shed.Sys.Os — ファイルシステムの小物

ここにあるのは glob だけ。core / Std に既にあるものはラップしない:

- 一時ファイル/ディレクトリ: `IO.FS.withTempFile` / `IO.FS.withTempDir`(ブラケット済み)
- 再帰走査: `System.FilePath.walkDir`
- 環境変数: `IO.getEnv`
- 日時: `Std.Time`(`PlainDateTime.now` の `toString` が ISO 8601)

## 失敗モード

- `root` が存在しない → `IO.Error`(walkDir 由来)
-/

namespace Shed.Sys.Os

open Shed.Pure.Glob

/-- `.` 始まりの名前(隠しファイル/ディレクトリ)か。 -/
private def isHiddenName (name : Option String) : Bool :=
  (name.getD "").startsWith "."

/--
`root` 以下を再帰的に歩き、`root` からの相対パスが glob パターンに
マッチするファイルを返す(`*` / `?` / `**`)。

**隠しディレクトリ・隠しファイル(`.` 始まり)は既定で除外**する —
リポジトリ直下で `**/*.lean` と書いたときに `.lake` や `.git` の中身を
歩かない・拾わないため。`.github` 等を対象にしたいときは
`includeHidden := true`。

```
let leanFiles ← glob "**/*.lean"
let sqls ← glob "models/**/*.sql" (root := "examples/dbt")
let workflows ← glob ".github/workflows/*.yml" (includeHidden := true)
```
-/
def glob (pattern : String) (root : System.FilePath := ".")
    (includeHidden : Bool := false) : IO (Array System.FilePath) := do
  let rootStr := root.toString
  let prefixLen := rootStr.length + 1  -- "root/" の分
  -- 隠しディレクトリは中に入らない(root 自身は名前に関わらず歩く)
  let files ← root.walkDir fun p =>
    pure (includeHidden || p.toString == rootStr || !isHiddenName p.fileName)
  pure <| files.filterMap fun f =>
    let rel := (f.toString.drop prefixLen).toString
    let hiddenSegment := rel.splitOn "/" |>.any (·.startsWith ".")
    if (includeHidden || !hiddenSegment) && matchPath pattern rel then
      some f
    else
      none

end Shed.Sys.Os
