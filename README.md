# shed

Lean 4 でスクリプト的な日常作業を書くための個人用ライブラリ。*Tools I needed twice.*

HTTP・正規表現・SQL(DuckDB)・glob・ログといった「いつも欲しくなる部品」と、
データエンジニアリング(dbt 連携)向けの道具を収める。

## 特徴

- **エンジンは運転する** — DB や正規表現エンジンを Lean で再実装しない。
  DuckDB や Python をサブプロセスとして裏で走らせ、型付きの JSON でやり取りする
- **8 割で十分** — Python の同等ライブラリとの機能網羅は目指さない。
  「自分が使う 8 割のケースを 2 割の API で」
- **既定で安全側** — IO にはタイムアウトの既定値がある(HTTP 30 秒、
  サブプロセス 120 秒)。無制限にするには `timeoutSec := 0` の明示が必要
- **全 API に動く使用例** — すべてのモジュールが examples/ か tests/ に
  実行可能な使用例を持ち、CI が全件実行する

## インストール

### 前提

- [elan](https://github.com/leanprover/elan)(Lean のバージョン管理。
  使う Lean は `lean-toolchain` が自動解決する)
- モジュールによっては外部コマンドを使う:

| 使いたいもの | 追加で必要なもの |
|---|---|
| `Sys.Http` | curl |
| `Sys.Regex` / `Sys.Py` | python3 |
| `Sys.Data` | python3 + `pip install duckdb` |
| それ以外(Pure 層・glob・ログなど) | なし |

### Lake プロジェクトから使う

`lakefile.toml` に追加して `import Shed`:

```toml
[[require]]
name = "shed"
git = "https://github.com/watanany/lean4-shed"
rev = "main"
```

### リポジトリ単体で試す

```sh
git clone https://github.com/watanany/lean4-shed
cd lean4-shed
lake build
lake env lean --run tests/Smoke.lean
```

## 使い方

HTTP GET(4xx/5xx は例外にせず `Response.ok` / `status` で判定):

```lean
open Shed.Sys.Http

let r ← get "https://example.com/api" (headers := #[("X-Token", "...")])
if r.ok then
  let json ← IO.ofExcept r.json
  ...
```

SQL で集計して Lean の型で受け取る:

```lean
open Shed.Sys.Data

structure StatusCount where
  status : String
  n : Nat
  deriving Lean.FromJson

withDuck fun db => do
  db.exec "create table t as select * from 'data.csv'"
  let counts ← db.queryAs StatusCount
    "select status, count(*)::int as n from t group by 1"
  ...
```

全機能を通しで見るには [examples/LogPipeline.lean](examples/LogPipeline.lean) —
アクセスログを「glob で発見 → 正規表現でパース → DuckDB で集計 → 契約生成 →
HTTP 配信検証」と流すミニ ETL(約 200 行)。

## モジュール一覧

詳細は各モジュール冒頭の doc コメントにある(使い方・失敗モード・
タイムアウトの注意がモジュールごとにまとまっている)。

| モジュール | 内容 | 使用例 |
|---|---|---|
| [`Sys.Http`](Shed/Sys/Http.lean) | HTTP クライアント(curl、タイムアウト既定 30 秒) | [tests/HttpTest.lean](tests/HttpTest.lean) |
| [`Sys.Regex`](Shed/Sys/Regex.lean) | PCRE 級の正規表現(Python re を運転) | [tests/RegexTest.lean](tests/RegexTest.lean) |
| [`Sys.Data`](Shed/Sys/Data.lean) | DuckDB の運転(SQL → 型付き行、一括投入) | [tests/DataTest.lean](tests/DataTest.lean) |
| [`Sys.Py`](Shed/Sys/Py.lean) | Python 脱出ハッチ(型は Lean のまま) | [tests/DataTest.lean](tests/DataTest.lean) |
| [`Pure.Glob`](Shed/Pure/Glob.lean) + [`Sys.Os`](Shed/Sys/Os.lean) | glob 照合と走査 | [tests/OsLogTest.lean](tests/OsLogTest.lean) |
| [`Sys.Log`](Shed/Sys/Log.lean) | ISO 8601 + レベルの最小ロガー | [tests/OsLogTest.lean](tests/OsLogTest.lean) |
| [`Sys.Subprocess`](Shed/Sys/Subprocess.lean) / [`Sys.Worker`](Shed/Sys/Worker.lean) | 単発 / 常駐のサブプロセス + JSON(タイムアウト既定 120 秒) | [tests/Smoke.lean](tests/Smoke.lean) |
| [`Pure.Contract`](Shed/Pure/Contract.lean) | データ契約の定義 → dbt / JSON Schema 生成 | [examples/Contracts.lean](examples/Contracts.lean) |
| [`Pure.Dbt`](Shed/Pure/Dbt.lean) + [`Sys.Dbt`](Shed/Sys/Dbt.lean) | dbt manifest のコンパイル時取り込みと規約検証 | [examples/DbtChecks.lean](examples/DbtChecks.lean) |
| (横断) | 上記ほぼ全部を使うミニ ETL | [examples/LogPipeline.lean](examples/LogPipeline.lean) |

Lean の標準ライブラリ(Std / core)に既にあるものはラップしない
(一時ファイル・walkDir・環境変数・日時は Lean 標準を直接使う)。

## 構造: Pure と Sys

名前空間は 2 層に分かれている。**目安: 計算だけなら Pure、外の世界
(ネットワーク・プロセス)に触るなら Sys**。

- **`Shed.Pure.*`** — 純粋な Lean 関数だけ。外部コマンド不要でどこでも動き、
  `#guard` の実行可能 example がコンパイル時に検証される
- **`Shed.Sys.*`** — 外部プロセス(curl・python3・DuckDB)をサブプロセスとして
  運転する層。`IO` を返す。外部接続はサブプロセス + JSON が主経路で、
  FFI は原則使わない

## dbt 連携

データエンジニアリング向けの専用道具。**データ契約**(テーブルの列・制約に
ついての取り決め)を**正本**(唯一の定義場所。それ以外は生成物なので手で
編集しない)として管理する。向きは 2 つ:

- **Lean が正本** — 契約を Lean の型で書き、dbt の schema.yml と JSON Schema を
  生成する。[examples/Contracts.lean](examples/Contracts.lean)
- **dbt が正本** — 既存 dbt プロジェクトの manifest.json をコンパイル時に
  取り込み、依存関係のルールを検査する。違反があると `lake build` が落ちる。
  [examples/DbtChecks.lean](examples/DbtChecks.lean)

実物の dbt に読ませて検証する手順は [examples/dbt/README.md](examples/dbt/README.md)。

## 開発

```sh
lake build                              # 変更ごとに通す
lake env lean --run tests/<名前>.lean   # テスト(CI が全件実行)
```

elan の配布サーバーに到達できない隔離環境では
`sudo python3 scripts/setup-lean-nix.py`(Nix バイナリキャッシュ経由で導入)。

## もっと詳しく

- [CLAUDE.md](CLAUDE.md) — 開発規約(現在有効なルールの正本)
- [docs/design.md](docs/design.md) — 設計の経緯(なぜこの設計なのか。追記型の記録)
- [docs/field-report-2026-07.md](docs/field-report-2026-07.md) — 実地評価レポート
