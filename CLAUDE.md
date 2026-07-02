# CLAUDE.md — lean4-shed

## プロジェクトの性格
- Lean 4 の個人用実験バッテリー「shed(物置)」。タグライン: *Tools I needed twice.*
- 作者はデータエンジニア。仕事の大半は AI を中間に置いて行われる
- **中心目的: AI 経由の仕事に「機械検査される小さな正本」という固定点を与えること**。
  AI が帰納で書き、検査器が門番をし、人間は契約層と日本語 doc だけを読む
- 副目的: Lean を日常の小道具が書ける言語にする(バッテリー整備)
- リポジトリ名 `lean4-shed` / パッケージ名 `shed` / ルート名前空間 `Shed`
- ドキュメント・コメントは日本語。英語ドキュメントは書かない
- 詳細設計と経緯は `docs/design.md`(作業前に必ず読む。特に追記セクション)

## アーキテクチャ
- **Pure/Sys の二層構成**
  - `Shed.Pure.*` — Lean のみで完結し検証可能なコード。契約カーネルはここ
  - `Shed.Sys.*` — 外部依存(サブプロセス等)を伴うコード
- 外部接続の主経路は **サブプロセス + JSON**。FFI は原則使わない
- **エンジンは移植せず運転する**: DataFrame・DB 等の重い処理系は pure Lean で
  再実装せず、型付き契約でサブプロセス(DuckDB、Python ワーカー)を駆動する
- 検証勾配: 型 < 効果 < 有界性 < 事後条件 < 証明。上位は必要になってから
- 効果は capability 型クラスで表現し、強制は lint 経由の opt-in

## トラック(優先順)
1. **契約カーネル** `Shed.Pure.Contract` — データ契約(スキーマ・不変条件)を
   Lean の型で正本化し、dbt schema tests / JSON Schema 等を**生成**する。
   実需: dlt/dbt/Dagster によるデータ連携プロジェクト
2. **職業標準バッテリー** — データエンジニアの日常セット。
   Http.Client(curl)→ Sys.Data(DuckDB 運転)→ Sys.Py(型付き契約で
   Python を呼ぶ脱出ハッチ)→ Os.Glob/Tempfile/Env・Dev.Log・Time.Iso8601(薄く)
3. **演繹の筋トレ** — 「はず」形式化・正当化論理(休眠可、削除しない)

## 横断規約
- 三段命名: `parse`(Except 系)/ `parse?`(Option)/ `parse!`(panic)
- リソースは必ずブラケット(`withXxx`)で提供する
- IO 操作は bounded-by-default(無制限読み込みをデフォルトにしない)
- 表層 API は単相。一般化は下層に隠す
- **消費者なきモジュール禁止**: 全モジュールは `examples/` か `tests/` に
  実行可能な消費者を持つ。持てないなら書かない
- **昇格則(旧・二回ルールの改訂)**: 実装は AI に任せられるため安いが、
  API 表面の一貫性とレビュー注意力は希少。職業標準セットは事前承認済み、
  それ以外は実需(実プロジェクト・実スクリプト)が発生してから
- **削除無料**: 依存者ゼロのうちは削除・破壊的変更を躊躇しない。
  使われない API は削除候補に挙げる
- Python の同等品と機能パリティを目指さない。「自分が使う8割のケースを
  2割の API で」
- **道具は知ってよい、プロジェクトは知らない**: `Shed.*` はツール
  (dbt / DuckDB / curl)固有のモジュールを持ってよいが、特定プロジェクトの
  名前・命名規約・テーブル定義をハードコードしない。規約はパラメータで注入
  (例: `Dbt.Conventions`)。プロジェクト固有物は消費者リポジトリか
  examples/(合成フィクスチャ)に置く。ツール固有トラックが育ったら
  別パッケージへの切り出しは自由(境界 = 名前空間なので機械的)

## やらないこと
- pure Lean の DataFrame / カラムナエンジン(エンジンは運転するもの)
- 線形型もどき・セッション型などの重い型機構(表層 API を壊す)
- WriterT(標準に無く、正格評価と相性が悪い。StateT で代替)
- 機能網羅を目的にしたモジュール実装
- 英語ドキュメント

## 技術知見(再調査不要)
- CJK 識別子は `«»` で囲む(lexer の isLetterLike が CJK を含まないため)
- stdin ハンドルは最終使用後に自動クローズ → EOF。
  Python ワーカー側は `flush=True` 必須
- 常駐ワーカーの stderr は `.inherit` にする(`.piped` はデッドロックし得る)
- Mutex は `Std.Mutex`(`import Std.Sync.Mutex`)。`IO.Mutex` は無い
- `Child.takeStdin` は `IO (IO.FS.Handle × Child {cfg with stdin := .null})`
- `IO.Process.Child ⟨.piped, .piped, .inherit⟩` の型パラメータ表記はそのまま通る
- match 腕の継続行は `=>` の右の項より深くインデントする(浅いと別項扱い)
- JSON は合法な YAML: dbt の .yml には Lean の `Json.pretty` 出力をそのまま使える
- モジュールドキュメント `/-! -/` は import より後に置く
- 書く前に toolchain の Std を確認する(HashMap 等かなり太っている)。
  外部依存(batteries 等)は toolchain 追従コストを負うため原則追加しない
- Std / core に既にある(ラップ不要): `IO.FS.withTempFile` / `withTempDir`、
  `System.FilePath.walkDir`、`IO.getEnv`、`Std.Time`
  (`PlainDateTime.now` の toString が ISO 8601)
- `String.drop` / `takeWhile` 等は 4.30 で `String.Slice` を返す(`.toString` が要る)

## 開発ループ
- toolchain は `lean-toolchain` で安定版最新に固定する
- 変更ごとに `lake build` を通す。ビルドが通らない状態でコミットしない
- Pure 層は doc comment + `#guard` の実行可能 example、
  Sys 層はスモークテスト(`lake env lean --run tests/Smoke.lean`)
- コミットは小さく、日本語メッセージで可
- 隔離環境(elan 配布サーバー遮断)では `scripts/setup-lean-nix.py` で
  toolchain を導入する
