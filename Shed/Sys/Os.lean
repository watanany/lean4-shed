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

/--
`root` 以下を再帰的に歩き、`root` からの相対パスが glob パターンに
マッチするファイルを返す(`*` / `?` / `**`)。

```
let leanFiles ← glob "**/*.lean"
let sqls ← glob "models/**/*.sql" (root := "examples/dbt")
```
-/
def glob (pattern : String) (root : System.FilePath := ".") : IO (Array System.FilePath) := do
  let prefixLen := root.toString.length + 1  -- "root/" の分
  let files ← root.walkDir
  pure <| files.filterMap fun f =>
    let rel := (f.toString.drop prefixLen).toString
    if matchPath pattern rel then some f else none

end Shed.Sys.Os
