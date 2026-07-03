# shed

Lean 4 の個人用実験バッテリー(道具箱)。*Tools I needed twice.*

HTTP・正規表現・SQL(DuckDB)・glob・ログといった、スクリプトを書くときに
いつも欲しくなる部品を Lean 4 で揃えたもの。後半にはデータエンジニアリング
(dbt 連携)向けの専用道具もある。

## 考え方(3 行)

- **エンジンは運転する**: DB や正規表現エンジンを Lean で再実装しない。
  DuckDB や Python をサブプロセスとして裏で走らせ、型付きの JSON でやり取りする
- **8 割で十分**: Python の同等ライブラリとの機能網羅は目指さない。
  「自分が使う 8 割のケースを 2 割の API で」
- **既定で安全側**: IO にはタイムアウトの既定値がある(HTTP 30 秒、
  サブプロセス 120 秒)。無制限にしたい人だけが明示的に `timeoutSec := 0` を選ぶ

動機や設計の経緯は [docs/design.md](docs/design.md)、開発規約は [CLAUDE.md](CLAUDE.md)。

## クイックスタート

```sh
lake build                                     # elan があれば toolchain は自動導入
lake env lean --run tests/Smoke.lean           # 動作確認(python3 が必要)
lake env lean --run examples/LogPipeline.lean  # 全部入りの実例(要 pip install duckdb)
```

[examples/LogPipeline.lean](examples/LogPipeline.lean) は Web サーバーのアクセスログを
「glob で発見 → 正規表現でパース → DuckDB で集計 → 型で回収 → HTTP で配信検証」と
一気通貫に流すミニ ETL。このライブラリのほぼ全機能が 200 行で見られる。

## 汎用の部品

### HTTP クライアント(`Shed.Sys.Http`)

curl の薄いラッパ。タイムアウトは既定 30 秒:

```lean
open Shed.Sys.Http

let r ← get "https://example.com/api" (headers := #[("X-Token", "...")])
if r.ok then
  let json ← IO.ofExcept r.json
  ...

let r ← postJson "https://example.com/api" (Lean.Json.mkObj [("n", (42 : Nat))])
```

4xx/5xx は例外にせず `Response.status` / `Response.ok` で判定する
(Python の requests と同じ流儀)。

### 正規表現(`Shed.Sys.Regex`)

先読み・後読み・後方参照・名前付きグループを含む PCRE 級の全機能。
再実装ではなく Python の `re` を裏で走らせるので、挙動は Python と完全に一致する:

```lean
open Shed.Sys.Regex

withRe fun re => do
  let ok ← re.test "\\d{4}-\\d{2}-\\d{2}" "2026-07-02"
  let m ← re.find? "(?P<user>\\w+)@(\\w+)" "taro@example"
  -- 名前付きグループは m.named? "user" で引ける
  let s ← re.replace "(\\w+)@(\\w+)" "taro@example" "\\2/\\1"
  let parts ← re.split "\\s*[,、]\\s*" "a, b、c"
```

パターンは裏側でキャッシュされ、同一パターンの反復は速い。

### SQL / DuckDB(`Shed.Sys.Data`)

CSV / Parquet / JSON の読み書き・結合・集計は SQL で書き、結果を Lean の型で
受け取る(要 `pip install duckdb`):

```lean
open Shed.Sys.Data

structure StatusCount where
  status : String
  n : Nat
  deriving Lean.FromJson

withDuck fun db => do
  db.exec "create table t as select * from 'data.csv'"
  let counts ← db.queryAs StatusCount "select status, count(*)::int as n from t group by 1"
  ...
```

値の埋め込みは `?` プレースホルダ + `params`(クォート事故なし)、
まとまった行の投入は `db.insertRows`(1 行ずつの INSERT を避ける)。

### Python 脱出ハッチ(`Shed.Sys.Py`)

どうしても Python が楽な処理は、制御フローと型を Lean に残したまま
式だけ Python に投げる:

```lean
let sorted : Array Nat ← Shed.Sys.Py.call "sorted(set(data))" #[3, 1, 3, 2]
```

入力は Python 側の変数 `data` に入り、式の評価結果が型検査されて返ってくる。

### ファイル探索(`Shed.Sys.Os` / `Shed.Pure.Glob`)

```lean
let leanFiles ← Shed.Sys.Os.glob "**/*.lean"                       -- .git / .lake は既定で除外
let sqls ← Shed.Sys.Os.glob "models/**/*.sql" (root := "examples/dbt")
let ci ← Shed.Sys.Os.glob ".github/workflows/*.yml" (includeHidden := true)
```

### ログ(`Shed.Sys.Log`)

ISO 8601 タイムスタンプ + レベルで stderr に 1 行出すだけの最小ロガー:

```lean
Shed.Sys.Log.info "取り込み開始"     -- 2026-07-02T09:00:00 [INFO] 取り込み開始
Shed.Sys.Log.warn s!"リトライ {n} 回目"
```

しきい値は環境変数 `SHED_LOG`(`debug` / `info` / `warn` / `error`、既定 `info`)。

### 土台: サブプロセス(`Shed.Sys.Subprocess`)と常駐ワーカー(`Shed.Sys.Worker`)

上の Http / Data / Regex はすべてこの 2 つの上に乗っている。
自分の外部ツールをつなぐときも同じ経路が使える。

単発呼び出し — stdin に書いて閉じ、stdout を読み切る:

```lean
open Shed.Sys

let out ← callRaw { exe := "cat" } "hello\n"

-- JSON in / JSON out(exit code ≠ 0 はエラー)
let res ← callJsonRaw
  { exe := "python3", args := #["-c", "import sys, json; print(json.dumps(json.load(sys.stdin)))"] }
  (Lean.Json.mkObj [("n", (42 : Nat))])
```

高頻度の呼び出しはプロセスを常駐させ、行区切り JSON でやり取りする
(呼び出しは Mutex で直列化されるので複数タスクから安全):

```lean
withWorker { exe := "python3", args := #["-c", workerPy] } fun w => do
  let res ← w.callJson (Lean.Json.mkObj [("id", (1 : Nat))])
  ...
```

ワーカー側(Python)は 1 行読むごとに 1 行返し、**必ず flush する**:

```python
import sys, json
for line in sys.stdin:
    req = json.loads(line)
    print(json.dumps({"echo": req}), flush=True)
```

## データエンジニアリング向け(dbt 連携)

ここから先は専用道具。先に言葉を 2 つだけ:

- **データ契約** — 「このテーブルにはこの列があり、NULL 不可・一意・許容値はこれ」
  という、データの形についての取り決め
- **正本(せいほん)** — その取り決めを定義する唯一の置き場所
  (single source of truth)。正本以外は生成物なので手で編集しない

### Lean で契約を書き、dbt / JSON Schema を生成する(`Shed.Pure.Contract`)

契約を Lean の型で一箇所に書き、そこから dbt の schema.yml(テスト定義)と
JSON Schema を生成する。Lean が正本、YAML は生成物:

```lean
def stgOrders : Model := {
  name := "stg_orders"
  columns := #[
    { name := "order_id", type := .integer, unique := true },
    { name := "status", type := .text,
      accepted := #["placed", "shipped", "completed", "returned"] } ]
}
-- (dbtSchema #[stgOrders]).pretty をそのまま schema.yml に書き出せる
-- (JSON は合法な YAML)
```

```sh
lake env lean --run examples/Contracts.lean examples/out
# → schema.yml(dbt)、<model>.schema.json(JSON Schema)
```

契約を変えるときは Lean 側を直して生成し直す。
実物の dbt に読ませて検証する手順は [examples/dbt/README.md](examples/dbt/README.md)。

### 既存 dbt プロジェクトの構造検査(`Shed.Pure.Dbt` / `Shed.Sys.Dbt`)

逆に、チームの正本が既に dbt(SQL)にある場合は、dbt が吐く manifest.json を
コンパイル時に Lean へ取り込み、dbt 単体では書けない検証
(モデル間の依存関係のルール)をかける。違反があると `lake build` が落ちる:

```lean
-- コンパイル時に manifest を読み込んで定数化
def_dbt_project proj from "path/to/target/manifest.json"

-- レイヤー規約(staging は生データのみ / mart は staging 経由)を
-- コンパイル時に検査。違反があると lake build が落ちる
dbt_check "path/to/target/manifest.json"
```

既存の dbt プロジェクト側に変更は要らない(manifest を読むだけ)。
使用例: [examples/DbtChecks.lean](examples/DbtChecks.lean)。

## モジュール一覧

すべてのモジュールは実行できる使用例(examples/ または tests/)を持つ:

| モジュール | 内容 | 実行できる使用例 |
|---|---|---|
| `Sys.Http` | HTTP クライアント(curl、タイムアウト既定 30 秒) | `tests/HttpTest.lean` |
| `Sys.Regex` | PCRE 級の正規表現(Python re を運転) | `tests/RegexTest.lean` |
| `Sys.Data` | DuckDB の運転(SQL → 型付き行、一括投入) | `tests/DataTest.lean` |
| `Sys.Py` | Python 脱出ハッチ(型は Lean のまま) | `tests/DataTest.lean` |
| `Pure.Glob` + `Sys.Os` | glob 照合と走査 | `tests/OsLogTest.lean` |
| `Sys.Log` | ISO 8601 + レベルの最小ロガー | `tests/OsLogTest.lean` |
| `Sys.Subprocess` / `Sys.Worker` | 単発 / 常駐のサブプロセス + JSON(タイムアウト既定 120 秒) | `tests/Smoke.lean` |
| `Pure.Contract` | データ契約の定義 → dbt / JSON Schema 生成 | `examples/Contracts.lean` |
| `Pure.Dbt` + `Sys.Dbt` | dbt manifest のコンパイル時取り込みと規約検証 | `examples/DbtChecks.lean` |
| (横断) | 上記ほぼ全部を使うミニ ETL | `examples/LogPipeline.lean` |

Lean の標準ライブラリ(Std / core)に既にあるものはラップしない
(一時ファイル・walkDir・環境変数・日時は Lean 標準を直接使う)。

## 構成

- `Shed.Pure.*` — Lean のみで完結し検証可能なコード
- `Shed.Sys.*` — 外部依存(サブプロセス等)を伴うコード

外部接続の主経路はサブプロセス + JSON。FFI は原則使わない。

## 開発環境

`lean-toolchain`(elan)で安定版最新に固定。elan が入っていれば追加の準備は不要。
elan の配布サーバーに到達できない隔離環境では
`sudo python3 scripts/setup-lean-nix.py`(Nix バイナリキャッシュ経由で導入)。
