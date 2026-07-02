# CLAUDE.md — lean4-shed

## プロジェクトの性格
- Lean 4 の個人用実験バッテリー「shed（物置）」。タグライン: *Tools I needed twice.*
- 網羅が目的ではない。「Lean で日常の小道具が書ける」状態が目的
- ほぼ使われない前提の実験場。注目獲得のための最適化はしない
- リポジトリ名 `lean4-shed` / パッケージ名 `shed` / ルート名前空間 `Shed`
- ドキュメント・コメントは日本語。英語ドキュメントは書かない
- 詳細設計は `docs/design.md`（存在する場合は作業前に必ず読む）

## アーキテクチャ
- **Pure/Sys の二層構成**
  - `Shed.Pure.*` — Lean のみで完結し検証可能なコード
  - `Shed.Sys.*` — 外部依存（サブプロセス等）を伴うコード
- 外部接続の主経路は **サブプロセス + JSON**。FFI は原則使わない
- 検証勾配: 型 < 効果 < 有界性 < 事後条件 < 証明。上位は必要になってから
- 効果は capability 型クラスで表現し、強制は lint 経由の opt-in

## 横断規約
- 三段命名: `parse`（Except 系）/ `parse?`（Option）/ `parse!`（panic）
- リソースは必ずブラケット（`withXxx`）で提供する
- IO 操作は bounded-by-default（無制限読み込みをデフォルトにしない）
- 表層 API は単相。一般化は下層に隠す
- **二回ルール**: 実プロジェクトで二回使ったものだけ昇格させる

## やらないこと
- 線形型もどき・セッション型などの重い型機構（表層 API を壊す）
- WriterT（標準に無く、正格評価と相性が悪い。StateT で代替）
- 推測ベースのモジュール先行実装（二回ルール違反）
- 英語ドキュメント

## 種コード（seed/ にある場合）
旧 plumbing パッケージを名前空間変更して取り込む:
- `Plumbing/Subprocess.lean` → `Shed/Sys/Subprocess.lean`
  （`Cmd` 構造体、`callRaw` / `callJsonRaw` / `call`）
- `Plumbing/Worker.lean` → `Shed/Sys/Worker.lean`
  （常駐ワーカー、Mutex による直列化、`withWorker` ブラケット、`shutdown`）

**未コンパイル**。最初の `lake build` での確認点:
1. `IO.Mutex` の所在（toolchain によっては `Std.Mutex`）
2. `IO.Process.Child ⟨.piped, .piped, .inherit⟩` の型パラメータ表記
3. `takeStdin` の返り値型

seed/ が無い場合は上記 API 記述から新規に書き起こしてよい。

## 技術知見（再調査不要）
- CJK 識別子は `«»` で囲む（lexer の isLetterLike が CJK を含まないため）
- stdin ハンドルは最終使用後に自動クローズ → EOF。
  Python ワーカー側は `flush=True` 必須
- 常駐ワーカーの stderr は `.inherit` にする（`.piped` はデッドロックし得る）

## モジュール計画
**第一波**（実需から逆算・この順で）:
1. `Shed.Sys.Subprocess` / `Shed.Sys.Worker` — 種コードの取り込み
2. `Shed.Sys.Http.Client` — 当面 curl サブプロセスで可。表層は `get` / `postJson`
3. `Shed.Sys.Llm` — Http の上の薄い層
4. `Shed.Pure.Text.Unicode` — NFC/NFKC 正規化、文字種判定。
   `Text.Ja`（ひらがな/カタカナ/漢字判定、簡易文分割）を含む
5. `Shed.Pure.Data.Csv`

**第二波以降**（必要になってから。先行実装しない）:
Time (ISO 8601) / Encoding.Base64・Hex・Url / Dev.Log / Dev.Test /
Os.Glob・Tempfile / Concurrent.Channel

## 開発ループ
- toolchain は `lean-toolchain` で安定版最新に固定する
- 変更ごとに `lake build` を通す。ビルドが通らない状態でコミットしない
- コミットは小さく、日本語メッセージで可
