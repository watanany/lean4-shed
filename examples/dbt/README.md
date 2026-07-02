# dbt 検証フィクスチャ

`Shed.Pure.Contract` が生成した schema.yml を**実物の dbt** に読ませて
検証するための最小プロジェクト(DuckDB アダプタ)。

`models/schema.yml` はここに置かない — 正本は `examples/Contracts.lean` の
契約定義であり、schema.yml は生成物。手で編集しない。

```sh
# 生成
lake env lean --run examples/Contracts.lean examples/out
cp examples/out/schema.yml examples/dbt/models/schema.yml

# 検証(要: pip install dbt-duckdb)
cd examples/dbt && python3 -m dbt.cli.main build --profiles-dir .
```

契約が実際に噛むことの確認(negative test):
`seeds/raw_orders.csv` に契約外の status(例: `cancelled`)の行を足すと
accepted_values テストが FAIL する。
