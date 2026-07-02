/-!
# Shed.Pure.Glob — glob パターン照合(純粋部分)

サポートするのは日常の8割: `*`(セグメント内の任意文字列)、`?`(任意の1文字)、
`**`(0 個以上のディレクトリ階層)。文字クラス `[...]` や `{a,b}` はやらない
(必要になってから)。

ファイルシステムを歩く側は `Shed.Sys.Os.glob`(こちらは照合のみ)。

なお toolchain の Std / core に既にあるものはラップしない:
一時ファイルは `IO.FS.withTempFile` / `withTempDir`、走査は
`System.FilePath.walkDir`、環境変数は `IO.getEnv`、日時は `Std.Time`。
-/

namespace Shed.Pure.Glob

/-- 1 セグメント(`/` を含まない部分)の照合。`*` と `?` を解釈する。 -/
def matchSegment (pattern text : List Char) : Bool :=
  match pattern, text with
  | [], [] => true
  | '*' :: ps, [] => matchSegment ps []
  | '*' :: ps, c :: cs =>
    -- `*` が空にマッチするか、1 文字食って続けるか
    matchSegment ps (c :: cs) || matchSegment ('*' :: ps) cs
  | '?' :: ps, _ :: cs => matchSegment ps cs
  | p :: ps, c :: cs => p == c && matchSegment ps cs
  | _, _ => false
termination_by (text.length, pattern.length)

/-- セグメント列の照合。`**` は 0 個以上のセグメントにマッチする。 -/
def matchSegments (pattern text : List (List Char)) : Bool :=
  match pattern, text with
  | [], [] => true
  | ['*', '*'] :: ps, [] => matchSegments ps []
  | ['*', '*'] :: ps, s :: ss =>
    -- `**` が空にマッチするか、1 セグメント食って続けるか
    matchSegments ps (s :: ss) || matchSegments (['*', '*'] :: ps) ss
  | p :: ps, s :: ss => matchSegment p s && matchSegments ps ss
  | _, _ => false
termination_by (text.length, pattern.length)

/--
glob パターンでパス(`/` 区切り・相対)を照合する。

```
matchPath "**/*.lean" "Shed/Sys/Http.lean"  -- true
```
-/
def matchPath (pattern path : String) : Bool :=
  matchSegments
    (pattern.splitOn "/" |>.map String.toList)
    (path.splitOn "/" |>.map String.toList)

-- example: セグメント内の * と ?
#guard matchPath "*.lean" "Shed.lean"
#guard !(matchPath "*.lean" "Shed/Sys.lean")  -- * は / を跨がない
#guard matchPath "st?_*.sql" "stg_orders.sql"

-- example: ** は階層を跨ぐ(0 階層でもよい)
#guard matchPath "**/*.lean" "Shed/Sys/Http.lean"
#guard matchPath "**/*.lean" "Shed.lean"
#guard matchPath "examples/**/schema.yml" "examples/dbt/models/schema.yml"

-- example: マッチしないもの
#guard !(matchPath "Shed/*.lean" "Shed/Sys/Http.lean")
#guard !(matchPath "**/*.sql" "Shed/Sys/Http.lean")

end Shed.Pure.Glob
