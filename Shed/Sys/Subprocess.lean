import Lean.Data.Json

/-!
# Shed.Sys.Subprocess — 単発サブプロセス呼び出し

外界との接続の第一選択: サブプロセス + JSON over stdin/stdout。

- 単発呼び出し: stdin に入力を書いて閉じ(EOF)、stdout を読み切る
- exit code ≠ 0 はエラー(`callJsonRaw` / `call` の場合)
- 高頻度の呼び出しには常駐ワーカー(`Shed.Sys.Worker`)を使う

## 失敗モード

- 実行ファイルが見つからない / 起動できない → `IO.Error`
- exit code ≠ 0(`callJsonRaw` / `call`)→ stderr を含む `IO.userError`
- stdout が JSON としてパースできない → `IO.userError`
- JSON は期待した型に変換できない(`call`)→ `IO.userError`

## 有界性の注意

タイムアウト・出力サイズ上限は**未実装**(stdout/stderr を無制限に読み切る)。
「デフォルト有界」規約とは緊張関係にあるが、種コードの API に忠実な v1 とし、
実需が出た時点で `Child.tryWait` ポーリング + `kill` による打ち切りを追加する。
-/

namespace Shed.Sys

/-- 実行するコマンドの指定。表層 API は単相(String / Array / FilePath)。 -/
structure Cmd where
  /-- 実行ファイル名またはパス -/
  exe : String
  /-- コマンドライン引数 -/
  args : Array String := #[]
  /-- 作業ディレクトリ(`none` なら親を引き継ぐ) -/
  cwd : Option System.FilePath := none
  /-- 追加・削除する環境変数(`none` で削除)。親の環境は引き継がれる -/
  env : Array (String × Option String) := #[]
  deriving Inhabited, Repr

/-- `Cmd` を指定の stdio 構成で起動する(下層ヘルパ)。 -/
def Cmd.spawn (cmd : Cmd) (cfg : IO.Process.StdioConfig) :
    IO (IO.Process.Child cfg) :=
  IO.Process.spawn
    { toStdioConfig := cfg
      cmd := cmd.exe
      args := cmd.args
      cwd := cmd.cwd
      env := cmd.env }

/--
コマンドを起動し、`input` を stdin に書き込んで閉じ(EOF)、
stdout / stderr を読み切って exit code とともに返す。

exit code ≠ 0 でもエラーにはしない(生の結果が欲しい層向け)。
デッドロック回避のため stdout / stderr は並行タスクで読む。
-/
def callRaw (cmd : Cmd) (input : String := "") : IO IO.Process.Output := do
  let child ← cmd.spawn ⟨.piped, .piped, .piped⟩
  let (stdin, child) ← child.takeStdin
  -- 書き込みと同時に読み出しタスクを走らせておく(パイプ詰まり回避)
  let stdout ← IO.asTask child.stdout.readToEnd .dedicated
  let stderr ← IO.asTask child.stderr.readToEnd .dedicated
  stdin.putStr input
  stdin.flush
  -- `stdin` はここが最終使用点: 参照が落ちて自動クローズ → 子プロセスに EOF
  let exitCode ← child.wait
  let stdout ← IO.ofExcept stdout.get
  let stderr ← IO.ofExcept stderr.get
  pure { exitCode, stdout, stderr }

/--
JSON を stdin に渡して呼び出し、stdout を JSON としてパースして返す。

失敗モード: exit code ≠ 0、または stdout が JSON でない場合に `IO.userError`。
-/
def callJsonRaw (cmd : Cmd) (input : Lean.Json) : IO Lean.Json := do
  let out ← callRaw cmd (input.compress ++ "\n")
  if out.exitCode != 0 then
    throw <| IO.userError
      s!"Shed.Sys.callJsonRaw: {cmd.exe} が exit code {out.exitCode} で失敗\n{out.stderr}"
  match Lean.Json.parse out.stdout with
  | .ok json => pure json
  | .error e =>
    throw <| IO.userError s!"Shed.Sys.callJsonRaw: {cmd.exe} の出力を JSON としてパースできない: {e}"

/--
型付きの単発呼び出し。契約の正本は Lean の型: 入力を `ToJson` で直列化し、
出力を `FromJson` で再検証する。

失敗モード: `callJsonRaw` のものに加えて、JSON が `β` に変換できない場合に
`IO.userError`。
-/
def call [Lean.ToJson α] [Lean.FromJson β] (cmd : Cmd) (input : α) : IO β := do
  let json ← callJsonRaw cmd (Lean.toJson input)
  match Lean.fromJson? json with
  | .ok b => pure b
  | .error e =>
    throw <| IO.userError s!"Shed.Sys.call: {cmd.exe} の応答が期待した型に合わない: {e}"

end Shed.Sys
