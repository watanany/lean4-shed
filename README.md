# shed

Lean 4 の個人用実験バッテリー。*Tools I needed twice.*

中心目的: AI 経由の仕事に「機械検査される小さな正本」という固定点を与えること。
規約は [CLAUDE.md](CLAUDE.md)、設計の経緯は [docs/design.md](docs/design.md)。

## 構成

- `Shed.Pure.*` — Lean のみで完結し検証可能なコード
- `Shed.Sys.*` — 外部依存(サブプロセス等)を伴うコード

外部接続の主経路はサブプロセス + JSON。FFI は原則使わない。
重い処理系(DataFrame・DB)は移植せず、型付き契約でサブプロセスとして運転する。

## 契約カーネル(`Shed.Pure.Contract`)

データ契約を Lean の型で正本化し、dbt schema tests / JSON Schema を生成する:

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

契約を変えるときは Lean 側を直して生成し直す。schema.yml は手で編集しない。
実物の dbt での検証手順は [examples/dbt/README.md](examples/dbt/README.md)。

## dbt manifest の取り込み(`Shed.Pure.Dbt` / `Shed.Sys.Dbt`)

逆向き — **dbt(SQL)が正本**のプロジェクトでは、manifest.json を
コンパイル時に Lean へ取り込み、dbt tests では書けない検証
(リネージ・レイヤー規約)を行う:

```lean
-- コンパイル時に manifest を読み込んで定数化
def_dbt_project proj from "path/to/target/manifest.json"

-- レイヤー規約(staging は生データのみ / mart は staging 経由)を
-- コンパイル時に検査。違反があると lake build が落ちる
dbt_check "path/to/target/manifest.json"
```

既存の dbt プロジェクトへの足跡はゼロ(manifest を読むだけ)。
消費者: [examples/DbtChecks.lean](examples/DbtChecks.lean)。

## ビルドとテスト

```sh
lake build
lake env lean --run tests/Smoke.lean   # python3 が必要
```

## 使用例

単発のサブプロセス呼び出し(`Shed.Sys.Subprocess`):

```lean
open Shed.Sys

-- stdin に書いて閉じ(EOF)、stdout を読み切る
let out ← callRaw { exe := "cat" } "hello\n"

-- JSON in / JSON out(exit code ≠ 0 はエラー)
let res ← callJsonRaw
  { exe := "python3", args := #["-c", "import sys, json; print(json.dumps(json.load(sys.stdin)))"] }
  (Lean.Json.mkObj [("n", (42 : Nat))])
```

常駐ワーカー(`Shed.Sys.Worker`)。行区切り JSON でやり取りし、
呼び出しは Mutex で直列化される:

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

## 開発環境

`lean-toolchain`(elan)で安定版最新に固定。通常は elan があれば何もしなくてよい。
elan の配布サーバーに到達できない隔離環境では `scripts/setup-lean-nix.py` を参照。
