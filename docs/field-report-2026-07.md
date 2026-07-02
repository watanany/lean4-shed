# 実地レポート: 横断消費者を初見で 1 本書いた記録(2026-07)

初見ユーザー(AI エージェント、隔離環境)として shed だけでミニ ETL
(`examples/LogPipeline.lean`)を書き、全モジュールを通過させた記録。
§15「初回接触の還流」と同じ趣旨で、摩擦点を解像度を落とさず残す。

## やったこと

- 隔離環境に `scripts/setup-lean-nix.py` で toolchain v4.30.0 を導入し `lake build`
- 既存テスト 5 本を全件実行(全緑)
- `examples/LogPipeline.lean` を新規作成: アクセスログを
  glob → 正規表現パース(不正 3 行を警告)→ DuckDB 集計(`queryAs` で型に回収)→
  Py オラクルと突き合わせ → 契約から schema.yml / JSON Schema 生成 →
  ローカル HTTP 配信して GET で正本一致を検証。構文エラー 1 件の修正後、初回実行で全緑
- 本命ループを README 手順どおり実行: 契約生成 → 実物 dbt 16 項目 PASS →
  manifest をコンパイル時取り込み(`def_dbt_project` / `dbt_check`)→ 全緑。
  negative test(契約外 status 追加)で accepted_values が FAIL 1 になることも確認

## 良かった点(証拠つき)

- **モジュール doc だけで書けた**。使い方スニペット + 失敗モード + 有界性の注意という
  doc の型が効いている。「params でクォート安全」「DATE は文字列で返る」「stderr は
  inherit」など、詰まる前に答えが書いてあった
- **つなぎ目が composable**。`withRe fun re => Data.withDuck fun db => ...` の
  ブラケットのネストは何の抵抗もなく通った。`queryAs` + `deriving FromJson` も
  snake_case の SQL 別名を合わせるだけで一発
- **三段命名と既定値の予測可能性**。`Response.ok` / glob の隠しディレクトリ既定除外 /
  タイムアウト既定 30 秒は、いずれも「予想した通り」の側に倒れていた
- **`Py.call "sorted(data)[len(data)//2]" bytesArr` が一行で型付きで返る**。
  脱出ハッチとして過不足がない
- **本命(契約カーネル)は一気通貫で本物**。Lean の契約 → 実物 dbt が読む →
  manifest が Lean に還る → `lake build` が契約ゲートになる。この輪が実際に回り、
  negative test も噛んだ。エラボレーション時 IO の実用例として教材価値が高い

## 摩擦点(解像度を落とさず)

1. **セットアップの穴 2 つ**: `setup-lean-nix.py` は (a) `zstd` コマンド必須なのに
   事前チェックがなく 650MB ダウンロード後に素の Traceback で死ぬ、(b) `elan` 導入済みが
   前提だが、隔離環境では elan 自体が取得できない(elan.lean-lang.org / GitHub とも 403)。
   今回は store path の bin を `/usr/local/bin` に symlink して回避した。
   スクリプト冒頭の preflight(zstd/elan)と、elan 不在時の symlink 案内が欲しい
2. **`Regex.Match` に名前付きグループの引き手がない**。全消費者が
   `m.named.find? (·.1 == key) |>.bind (·.2)` を自作することになる。
   `Match.named? : Match → String → Option String` は昇格に値するはず
3. **`Sys.Data` に一括投入の慣用句がない**。行ごとの `exec insert` は 1 行 = 1 往復。
   23 行なら無問題だが実データでは即詰まる。エンジン運転の思想なら
   「一時 CSV/JSON に書いて `create table as select * from 'file'`」が正道のはずで、
   doc に慣用句として一行あるだけで違う
4. **「デフォルト有界」の実装が Http だけ**。Subprocess / Worker / Py / Data は
   タイムアウト未実装(doc には明記されている)。Regex はバックトラック型なので
   病的パターンで無限に待つ。規約と実装の最大のギャップ
5. **examples の生成物衝突**: `Contracts.lean` と新 example が両方
   `examples/out/schema.yml` に書いて上書きし合った(新側を `examples/out/access/` に
   変更して回避)。example ごとの出力サブディレクトリを慣例にすべき
6. **構造体リテラルの継続行インデント**で 1 回コンパイルエラー
   (`unexpected identifier; expected '}'`)。CLAUDE.md の match 腕の知見と同種。
   技術知見に「構造体リテラルの複数行はフィールドを `{` より深く」を足す価値あり
7. 4.30 の `String.trim` deprecation(→ `trimAscii`)を実地で踏んだ。既知の
   Slice 移行の一部

## 採点(10 点満点、初見で使った実感)

| 対象 | 点 | 一言 |
|---|---|---|
| Pure.Contract | 9 | 小さく正確。生成と実行時検証の両方に同じ正本が効く |
| Pure.Dbt + Sys.Dbt | 9 | 最も独創的。`lake build` = 契約ゲートが実際に回る |
| Sys.Subprocess / Worker | 9 | 土台の信頼感。EPIPE・並行・冪等 shutdown をテストが証明 |
| Sys.Py | 9 | 過不足のない脱出ハッチ |
| Sys.Regex | 8.5 | 初日から PCRE 全部は正しい。Match の引き手だけ不足 |
| Pure.Glob + Sys.Os | 8.5 | 隠し除外の既定が正しい。`**` も仕様どおり |
| Sys.Http | 8 | 8割用途に十分。本文はテキスト前提 |
| Sys.Log | 7.5 | 看板どおり最小。それ以上でも以下でもない |
| Sys.Data | 7 | queryAs は良い。一括投入の慣用句と有界性が未整備 |
| セットアップ体験 | 6.5 | nix 経路は救世主だが preflight の穴 2 つ |
| **総合** | **8.5** | 思想が API の細部まで一貫して届いている。穴は少数で特定済み |

## 学習価値の評価

高い。理由は網羅性ではなく**一貫性**:

- 「エンジンは運転する」が Regex(re)・Data(DuckDB)・Py で同じ形をしており、
  一つ覚えると全部読める
- Sys.Dbt はエラボレーション時 IO が実務の役に立つ稀有な実例で、
  Lean メタプログラミングの入口として教材になる
- 全公開関数の doc + `#guard` + 消費者の三点セットが「読めば書ける」を実現している。
  実際、本レポートの筆者は module doc と既存消費者の模倣だけで 1 本書けた

Python パリティを求める人には向かない。それは欠点ではなく仕様(8割/2割)。
