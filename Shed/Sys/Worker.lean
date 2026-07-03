import Std.Sync.Mutex
import Shed.Sys.Subprocess

/-!
# Shed.Sys.Worker — 常駐ワーカー

高頻度のサブプロセス呼び出し向け。子プロセスを常駐させ、
行区切り JSON(1 リクエスト = 1 行、1 レスポンス = 1 行)でやり取りする。

- リクエスト/レスポンスは `Std.Mutex` で直列化する(複数タスクから安全に呼べる)
- stderr は `.inherit`(`.piped` にするとバッファ詰まりでデッドロックし得る)
- 資源はブラケット規約に従い `withWorker` で使う

## ワーカー側プロトコル

stdin から 1 行読むごとに、応答を 1 行書いて **必ず flush** する。
Python なら `print(json.dumps(...), flush=True)`。flush を忘れると
呼び出し側が応答待ちで固まる。

## 失敗モード

- 起動失敗 → `IO.Error`
- shutdown 済みワーカーへの呼び出し → `IO.userError`
- ワーカーが応答前に終了(EOF)→ `IO.userError`
- 応答行が JSON としてパースできない / 型に合わない → `IO.userError`

## 有界性の注意

**応答待ちタイムアウト既定 120 秒**(bounded-by-default、`0` で無制限)。
時間切れは行区切りプロトコルの同期が壊れたことを意味するので、ワーカーを
kill して `finished` に落とす(以後の呼び出しはエラー)。
`shutdown` も既定 30 秒まで自然終了を待ち、それでも残る場合は kill する
(EOF を無視する行儀の悪いワーカーへの保険)。
-/

namespace Shed.Sys

/-- ワーカーの内部状態(`Std.Mutex` が保護する)。 -/
inductive Worker.State where
  /-- 稼働中。stdin ハンドルを保持する -/
  | running (stdin : IO.FS.Handle)
  /-- shutdown 済み。exit code を記録する -/
  | finished (exitCode : UInt32)

/-- 常駐ワーカー。`Worker.spawn` または `withWorker` で作る。 -/
structure Worker where
  private child : IO.Process.Child ⟨.null, .piped, .inherit⟩
  private state : Std.Mutex Worker.State

/-- ワーカーを起動する。解放を保証したい通常の用途では `withWorker` を使うこと。 -/
def Worker.spawn (cmd : Cmd) : IO Worker := do
  let child ← cmd.spawn ⟨.piped, .piped, .inherit⟩
  let (stdin, child) ← child.takeStdin
  let state ← Std.Mutex.new (.running stdin)
  pure { child, state }

/--
リクエスト JSON を 1 行書き、レスポンス JSON を 1 行読む。
Mutex により呼び出し全体が直列化されるため、複数タスクから同時に呼んでも
リクエストとレスポンスの対応は崩れない。

タイムアウト(既定 120 秒、`0` で無制限)を超えたら、プロトコルの同期が
壊れているためワーカーを kill して `IO.userError`(タイムアウトは
Mutex 取得後から数える)。
-/
def Worker.callJson (w : Worker) (req : Lean.Json) (timeoutSec : Nat := defaultTimeoutSec) :
    IO Lean.Json :=
  w.state.atomically do
    let .running stdin ← get
      | throw <| IO.userError "Shed.Sys.Worker.callJson: shutdown 済みのワーカー"
    stdin.putStr (req.compress ++ "\n")
    stdin.flush
    let line ←
      if timeoutSec == 0 then
        w.child.stdout.getLine
      else
        -- 読みをタスクに逃がし、期限つきで完了をポーリングする
        let read ← IO.asTask w.child.stdout.getLine .dedicated
        let done ← pollDeadline timeoutSec do
          if ← IO.hasFinished read then pure (some read.get) else pure none
        match done with
        | some line => IO.ofExcept line
        | none =>
          -- 応答と質問の対応が取れなくなったので、このワーカーは終わり
          w.child.kill
          let exitCode ← w.child.wait
          set (Worker.State.finished exitCode)
          throw <| IO.userError
            s!"Shed.Sys.Worker.callJson: {timeoutSec} 秒以内に応答がないため打ち切った(ワーカーは kill 済み)"
    if line.isEmpty then
      throw <| IO.userError
        "Shed.Sys.Worker.callJson: ワーカーが応答前に終了した(EOF)"
    match Lean.Json.parse line with
    | .ok json => pure json
    | .error e =>
      throw <| IO.userError s!"Shed.Sys.Worker.callJson: 応答を JSON としてパースできない: {e}"

/-- 型付きのワーカー呼び出し。入出力の契約は Lean の型(`ToJson` / `FromJson`)。 -/
def Worker.call [Lean.ToJson α] [Lean.FromJson β] (w : Worker) (input : α)
    (timeoutSec : Nat := defaultTimeoutSec) : IO β := do
  let json ← w.callJson (Lean.toJson input) timeoutSec
  match Lean.fromJson? json with
  | .ok b => pure b
  | .error e =>
    throw <| IO.userError s!"Shed.Sys.Worker.call: 応答が期待した型に合わない: {e}"

/--
ワーカーを終了させ、exit code を返す。

stdin ハンドルを手放すことで子プロセスに EOF を送り、自然終了を待つ。
`timeoutSec`(既定 30 秒、`0` で無制限)以内に終了しなければ kill する
(EOF を無視するワーカーで `withWorker` が固まらないための保険)。
冪等: 二度目以降は記録済みの exit code を返す。
-/
def Worker.shutdown (w : Worker) (timeoutSec : Nat := 30) : IO UInt32 :=
  w.state.atomically do
    match ← get with
    | .finished exitCode => pure exitCode
    | .running _ => do
      -- stdin への参照を状態ごと捨てる → 自動クローズ → 子プロセスに EOF
      set (Worker.State.finished 0)
      let exitCode ←
        if timeoutSec == 0 then
          w.child.wait
        else do
          match ← pollDeadline timeoutSec w.child.tryWait with
          | some code => pure code
          | none =>
            w.child.kill
            w.child.wait
      set (Worker.State.finished exitCode)
      pure exitCode

/--
ワーカーを起動して `f` に渡し、終了時(例外時含む)に必ず shutdown する
ブラケット。資源提供の標準経路。
-/
def withWorker (cmd : Cmd) (f : Worker → IO α) : IO α := do
  let w ← Worker.spawn cmd
  try
    f w
  finally
    discard w.shutdown

end Shed.Sys
