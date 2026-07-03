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

## 追記: 改修の還流(同ブランチ、レポート提出直後)

§15 の流儀で、摩擦点は指摘で終わらせず即日改修した。

1. **タイムアウト実装(摩擦点 4 → 解消)**: Subprocess の doc が予告していた
   `Child.tryWait` ポーリング + `kill` をそのまま実装。`callRaw` / `callJsonRaw` /
   `call` と `Worker.callJson` / `call` に `timeoutSec := 120`(`0` で無制限)。
   Worker は時間切れ = プロトコル同期の崩壊なので kill して `finished` に落とす。
   `Worker.shutdown` も既定 30 秒で kill にエスカレーション(EOF を無視する
   ワーカーで `withWorker` が固まらない)。Py / Data / Regex / Http に波及済み
   (Http は curl の `--max-time` が第一境界のまま、外側は +10 秒の保険)。
   打ち切りの実測は 1.0 秒指定で 1004〜1012ms(tests/Smoke.lean)
2. **`Regex.Match.named?` を昇格(摩擦点 2 → 解消)**: `#guard` example つき。
   LogPipeline の自作ヘルパは削除して置き換え
3. **`Duck.insertRows` を追加(摩擦点 3 → 解消)**: 一時ファイル +
   `read_json` + `insert into ... by name` の一括投入。キー順不同・クォート・
   日本語・空配列を tests/DataTest.lean で固定。LogPipeline も切り替え
4. **セットアップの穴(摩擦点 1 → 解消)**: `setup-lean-nix.py` に
   preflight(curl / zstd / xz)を追加し、elan 不在時は `/usr/local/bin` への
   symlink で代替する `register` に分離。elan なしの隔離環境で完走を確認
5. **CLAUDE.md 技術知見に 2 件追記(摩擦点 6・7)**: 構造体リテラルの
   複数行インデント、`String.trim` deprecated(`trimAscii`)。
   Http.lean に残っていた `String.trim` も退治

これで採点表の主な減点要因(有界性ギャップ、Match の引き手、一括投入、
セットアップ)は解消。残る既知の未実装は「出力サイズ上限」と「結果行数上限」
(実需待ち。doc に明記済み)。

## 追記 2: 包括レビューの還流(同ブランチ)

追記 1 の改修自体に 8 観点の並行レビューをかけた。最重要の発見は
**タイムアウト実装が招いた約 222 倍の性能退行**(echo ワーカー実測
46µs → 10,227µs/call)。ポーリングが初回チェック直後に無条件で
`IO.sleep 10` に入る構造が原因で、µs 級の応答が全部 10ms に丸まっていた。
Smoke テストがタイムアウトの**発火側**しか測っておらず見逃した。
教訓: **有界性の追加は happy path の計測とセット**。

改修(すべて同ブランチで実施済み):

- ポーリングを `Shed.Sys.pollDeadline` に一本化(三段バックオフ:
  経過 1ms までスピン → 20ms まで 1ms → 以後 10ms)。3 箇所の手書きループと
  `unreachable!` / `Option.get!` が消え、実測 113µs/call に回復
  (無制限時 36µs、タイムアウト発火側は 1004〜1010ms のまま)
- Smoke に退行トリップワイヤ: echo 200 往復 < 1 秒(退化すると 2 秒超で落ちる)
- `insertRows` のエスケープ漏れ: 識別子の `"` とパスの `'` を二重化
  (`"` 入りテーブル名のテストを DataTest に追加)
- 消費者なきタイムアウトの解消: Duck の重いクエリ打ち切り + 打ち切り後は
  その Duck が使えないこと + Py の `time.sleep` 式打ち切りを DataTest で固定
- `parseLine` → `parseLine?`(三段命名違反。examples は規約のショーケースなので)
- サーバー起動待ちループの欠陥修正(成功で break せず 50 回回る /
  non-2xx で sleep なし連打。同型の HttpTest も修正)
- `defaultTimeoutSec` 定数化(`120` が 11 シグネチャに散在していた)
- setup script: `/usr/local/bin` の実体ファイルを黙って消さない
  (上書きは自分が張った /nix/store 向き symlink のみ。実体があれば張る前に失敗)

レビューで「問題なし」と確認できたもの: `Http.outerTimeout` の層
(無いと明示タイムアウト > 120 秒が先に切られる)、Worker タイムアウト時の
kill 方式(行プロトコルでは正しい深さ)、`check` ヘルパの各消費者重複(既存規約)。
