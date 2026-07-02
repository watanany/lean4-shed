/-!
# Shed.Pure.Glob — glob パターン照合(純粋部分)

fnmatch 相当の**完全な glob 仕様**を実装する: `*`(セグメント内の任意文字列)、
`?`(任意の1文字)、`[...]` / `[!...]`(文字クラス。範囲 `a-z` 可、
先頭の `]` はリテラル、閉じない `[` はリテラル)、
`**`(0 個以上のディレクトリ階層)。

この仕様で**完成**であり、これ以上は足さない。ブレース展開 `{a,b}` は
シェルの拡張であって glob の仕様ではないため対象外(規約
「確定需要の原語は閉じた仕様を宣言して一度で完成させる」)。

本モジュールは照合のみを持ち、ファイルシステムを歩く側は `Shed.Sys.Os.glob`。

なお toolchain の Std / core に既にあるものはラップしない:
一時ファイルは `IO.FS.withTempFile` / `withTempDir`、走査は
`System.FilePath.walkDir`、環境変数は `IO.getEnv`、日時は `Std.Time`。
-/

namespace Shed.Pure.Glob

/-- 文字クラスの中身を読む。`(範囲の列, 残りのパターン)` を返す。
先頭の `]` はリテラル、`a-b` は範囲(コードポイント順)。
閉じ `]` が無ければ `none`(呼び出し側は `[` をリテラル扱いする)。 -/
private def readClass (cs : List Char) : Option (List (Char × Char) × List Char) :=
  go cs [] true
where
  go : List Char → List (Char × Char) → Bool → Option (List (Char × Char) × List Char)
    | [], _, _ => none
    | ']' :: rest, acc, first =>
      if first then go rest ((']', ']') :: acc) false
      else some (acc.reverse, rest)
    | a :: '-' :: b :: rest, acc, _ =>
      if b == ']' then
        -- `a-]`: `-` は末尾のリテラル
        go (']' :: rest) (('-', '-') :: (a, a) :: acc) false
      else go rest ((a, b) :: acc) false
    | a :: rest, acc, _ => go rest ((a, a) :: acc) false
  termination_by cs _ _ => cs.length

/-- 1 セグメント(`/` を含まない部分)の照合。`*`・`?`・`[...]` を解釈する。 -/
def matchSegment (pattern text : List Char) : Bool :=
  match pattern, text with
  | [], [] => true
  | '*' :: ps, [] => matchSegment ps []
  | '*' :: ps, c :: cs =>
    -- `*` が空にマッチするか、1 文字食って続けるか
    matchSegment ps (c :: cs) || matchSegment ('*' :: ps) cs
  | '?' :: ps, _ :: cs => matchSegment ps cs
  | '[' :: ps, c :: cs =>
    let (neg, body) := match ps with
      | '!' :: rest => (true, rest)
      | _ => (false, ps)
    match readClass body with
    | some (items, rest) =>
      let hit := items.any fun (lo, hi) => lo ≤ c && c ≤ hi
      hit != neg && matchSegment rest cs
    | none =>
      -- 閉じない `[` はリテラル(fnmatch と同じ)
      c == '[' && matchSegment ps cs
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

-- example: 文字クラス
#guard matchPath "data_[0-9].csv" "data_3.csv"
#guard !(matchPath "data_[0-9].csv" "data_x.csv")
#guard matchPath "[abc]*.lean" "a_test.lean"
#guard matchPath "[!0-9]*" "x1"           -- 否定クラス
#guard !(matchPath "[!0-9]*" "1x")
#guard matchPath "a[-z]b" "a-b"           -- 末尾の - はリテラル
#guard matchPath "x[]]y" "x]y"            -- 先頭の ] はリテラル
#guard matchPath "a[b" "a[b"              -- 閉じない [ はリテラル

-- example: マッチしないもの
#guard !(matchPath "Shed/*.lean" "Shed/Sys/Http.lean")
#guard !(matchPath "**/*.sql" "Shed/Sys/Http.lean")

end Shed.Pure.Glob
