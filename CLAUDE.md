# CLAUDE.md — lean4-shed

## プロジェクトの性格
- Lean 4 の個人用の実験場「shed(物置)」。タグライン: *Tools I needed twice.*
- 作者はデータエンジニア。仕事の大半は AI を間に置いて進める
- **中心の目的: AI 経由の仕事に「機械が検査できる小さな大もと」という動かない
  基準を与えること**。AI が実装を書き、検査器が関門になり、人間は契約の層と
  日本語の doc だけを読む
- もう一つの目的: Lean を日常の小道具が書ける言語にする(道具の整備)
- リポジトリ名 `lean4-shed` / パッケージ名 `shed` / ルート名前空間 `Shed`
- ドキュメント・コメントは日本語。英語ドキュメントは書かない
- **規約の大もとはこのファイル**。設計の経緯・理由は `docs/design.md`
  (追記していく記録。作業前に追記部分に目を通す)

## アーキテクチャ
- **Pure/Sys の二層構成**
  - `Shed.Pure.*` — Lean だけで完結し検証できるコード。契約の中核はここ
  - `Shed.Sys.*` — 外部依存(サブプロセス等)を伴うコード
- 外部接続の主な経路は **サブプロセス + JSON**。FFI は原則使わない
- **エンジンは作り直さず、外から呼んで使う**: DataFrame・DB 等の重い処理系は
  pure Lean で再実装せず、型付きの取り決めでサブプロセス(DuckDB、Python
  ワーカー)を動かす
- 検証の段階: 型 < 効果 < 有界性 < 事後条件 < 証明。上の段階は必要になってから
- 効果は capability 型クラスで表し、強制は lint による opt-in(手動で有効化)

## トラック(優先順)
1. **契約の中核** `Shed.Pure.Contract` — データの取り決め(スキーマ・不変条件)を
   Lean の型で定義の大もとにし、dbt schema tests / JSON Schema 等を**生成**する。
   使う場面: dlt/dbt/Dagster によるデータ連携プロジェクト
2. **仕事の定番セット** — データエンジニアの日常の道具。
   Sys.Http(curl)/ Sys.Data(DuckDB を動かす)/ Sys.Py(型付きの取り決めで
   Python を呼ぶ逃げ道)/ Sys.Regex / Sys.Os.glob / Sys.Log
   (一時ファイル・環境変数・日時は Std を直接使う)
3. **証明を読む練習** — 「はず」形式化・正当化論理(休ませてよい、削除しない)

## 横断規約
- 三段命名: `parse`(Except 系)/ `parse?`(Option)/ `parse!`(panic)
- リソースは必ずブラケット(`withXxx`)で提供する
- IO 操作は既定で有界(無制限の読み込みを既定にしない)
- 表層 API は単相。一般化は下層に隠す
- **使う例のないモジュールは作らない**: 全モジュールは `examples/` か `tests/` に
  実行できる使用例を持つ。持てないなら書かない
- **収録の基準(旧・二回ルールの見直し)**: 実装は AI に任せられるので安いが、
  API 表面の一貫性とレビューの注意力は貴重。定番セットは承認済み、
  それ以外は実際に必要になってから(実プロジェクト・実スクリプト)
- **削除は気軽に**: 依存する人がゼロのうちは削除・作り替えをためらわない。
  使われない API は削除候補に挙げる
- **使うと決まっている基本部品は一度で仕上げる**: glob・正規表現・CLI 引数の
  ような「使うことが決まっている基本部品」は 8 割で止めず、**仕様を決め切って**
  仕上げる(例: glob = fnmatch 相当で完成、正規表現 = エンジンを呼んで使う
  `Sys.Regex` で PCRE 級を完成。線形時間が要る純粋な文脈用の `Pure.Regex` は
  必要になったら併設 — design.md §18)。8 割ルールは仕様が決まらない
  モジュールにだけ適用する
- Python の同等品と機能を同じにはしない。「自分が使う 8 割のケースを
  2 割の API で」
- **道具は知ってよい、プロジェクトは知らない**: `Shed.*` はツール
  (dbt / DuckDB / curl)ごとのモジュールを持ってよいが、特定プロジェクトの
  名前・命名規約・テーブル定義をハードコードしない。規約はパラメータで渡す
  (例: `Dbt.Conventions`)。プロジェクト固有のものは使う側のリポジトリか
  examples/(合成した例)に置く。ツールごとのトラックが育ったら
  別パッケージへ切り出すのは自由(境界 = 名前空間なので機械的にできる)

## やらないこと
- pure Lean の DataFrame / カラムナエンジン(エンジンは呼んで使うもの)
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
- 構造体リテラルを関数適用の引数内で複数行に割ると、継続行のインデントが
  浅い場合に `expected '}'` になる。複数行になる構造体は let で束縛してから渡す
- JSON は合法な YAML: dbt の .yml には Lean の `Json.pretty` 出力をそのまま使える
- モジュールドキュメント `/-! -/` は import より後に置く
- 書く前に toolchain の Std を確認する(HashMap 等かなり太っている)。
  外部依存(batteries 等)は toolchain 追従コストを負うため原則追加しない
- Std / core に既にある(ラップ不要): `IO.FS.withTempFile` / `withTempDir`、
  `System.FilePath.walkDir`、`IO.getEnv`、`Std.Time`
  (`PlainDateTime.now` の toString が ISO 8601)
- `String.drop` / `takeWhile` 等は 4.30 で `String.Slice` を返す(`.toString` が要る)。
  `String.trim` は deprecated(`trimAscii` を使う。これも Slice を返す)
- `lake env lean --run` は再ビルドしない(古い olean を読む)。
  ライブラリを変更したら先に `lake build`
- ポーリング待ちに一定間隔 sleep を使わない(µs 級の応答が sleep 粒度に丸まり
  実測 222 倍退行した)。期限つき待ちは `Shed.Sys.pollDeadline`(三段バックオフ)を使う

## 開発ループ
- toolchain は `lean-toolchain` で安定版最新に固定する
- 変更ごとに `lake build` を通す。ビルドが通らない状態でコミットしない
- Pure 層は doc comment + `#guard` の実行可能 example、
  Sys 層は tests/ 以下の実挙動テスト(`lake env lean --run tests/<名前>.lean`。
  CI が全件実行する)
- コミットは小さく、日本語メッセージで可
- 隔離環境(elan 配布サーバー遮断)では `scripts/setup-lean-nix.py` で
  toolchain を導入する

## 協働スタイル(エージェント向け)
- 後出しジャンケン禁止: 前提・確認点・制約・リスクは最初の応答で全部出す
- 正確性を最優先: 記憶や推測で断言しない。未検証のものは「未検証」と明記する
- 網羅性を偽らない: 「確認できた範囲」を「全件」のように見せない
- 媚びない・褒めすぎない。誤りは率直に認める
- 「改善」と称して大げさにしない(設計の対話で最も繰り返された修正は
  「現実的な規模に戻すこと」だった)
- ユーザーへの質問は選択式が好ましい。応答は日本語・中立的な丁寧体
