import Shed

/-!
# スモークテスト

`Shed.Sys.Subprocess` / `Shed.Sys.Worker` を実プロセス相手に検証する。
python3 が PATH にあることが前提。

実行: `lake env lean --run tests/Smoke.lean`
(インタープリタ実行なので C コンパイラ不要)
-/

open Shed.Sys

def check (label : String) (cond : Bool) : IO Unit := do
  if cond then
    IO.println s!"ok: {label}"
  else
    throw <| IO.userError s!"NG: {label}"

/-- 行区切り JSON の echo ワーカー(Python)。flush=True が必須。 -/
def echoWorkerPy : String :=
  "import sys, json
for line in sys.stdin:
    req = json.loads(line)
    print(json.dumps({'echo': req}), flush=True)"

def main : IO Unit := do
  -- callRaw: cat による echo back
  let out ← callRaw { exe := "cat" } "こんにちは\n"
  check "callRaw: exit code 0" (out.exitCode == 0)
  check "callRaw: stdout が入力と一致" (out.stdout == "こんにちは\n")

  -- callRaw: 非ゼロ exit code はエラーにしない
  let out ← callRaw { exe := "false" }
  check "callRaw: false の exit code は非ゼロ" (out.exitCode != 0)

  -- callRaw: stdin を読まない子に大きな入力(EPIPE 経路でもゾンビ化しない)
  let big := String.join (List.replicate 100000 "0123456789")
  let out ← callRaw { exe := "false" } big
  check "callRaw: EPIPE 経路でも exit code が返る" (out.exitCode != 0)

  -- callJsonRaw: Python 経由の JSON roundtrip
  let inc : Cmd :=
    { exe := "python3"
      args := #["-c", "import sys, json; d = json.load(sys.stdin); d['n'] += 1; print(json.dumps(d))"] }
  let res ← callJsonRaw inc (Lean.Json.mkObj [("n", (41 : Nat))])
  check "callJsonRaw: n が 42 になる" (res.getObjValD "n" == (42 : Nat))

  -- callJsonRaw: exit code ≠ 0 は IO.userError
  let failed ← try
    discard <| callJsonRaw { exe := "python3", args := #["-c", "import sys; sys.exit(3)"] } (Lean.Json.mkObj [])
    pure false
  catch _ => pure true
  check "callJsonRaw: 非ゼロ exit はエラー" failed

  -- Worker: 直列の複数リクエスト
  withWorker { exe := "python3", args := #["-c", echoWorkerPy] } fun w => do
    for i in [0:5] do
      let req := Lean.Json.mkObj [("id", (i : Nat))]
      let res ← w.callJson req
      check s!"Worker: リクエスト {i} の echo back" (res.getObjValD "echo" == req)

    -- Worker: 複数タスクからの並行呼び出し(Mutex による直列化)
    let tasks ← (Array.range 8).mapM fun i =>
      IO.asTask (prio := .dedicated) do
        let req := Lean.Json.mkObj [("task", (i : Nat))]
        let res ← w.callJson req
        pure (res.getObjValD "echo" == req)
    for t in tasks, i in [0:8] do
      check s!"Worker: 並行タスク {i} の対応が正しい" (← IO.ofExcept t.get)

  -- Worker: shutdown の冪等性と exit code
  let w ← Worker.spawn { exe := "python3", args := #["-c", echoWorkerPy] }
  let code1 ← w.shutdown
  let code2 ← w.shutdown
  check "Worker: shutdown で exit code 0" (code1 == 0)
  check "Worker: shutdown は冪等" (code1 == code2)

  -- Worker: shutdown 後の呼び出しはエラー
  let failed ← try
    discard <| w.callJson (Lean.Json.mkObj [])
    pure false
  catch _ => pure true
  check "Worker: shutdown 後の呼び出しはエラー" failed

  -- callRaw: タイムアウトで kill され IO.userError(bounded-by-default)
  let t0 ← IO.monoMsNow
  let timedOut ← try
    discard <| callRaw { exe := "sleep", args := #["30"] } (timeoutSec := 1)
    pure false
  catch _ => pure true
  let elapsedMs := (← IO.monoMsNow) - t0
  check "callRaw: タイムアウトは IO.userError" timedOut
  check s!"callRaw: 打ち切りは期限近傍で起きる({elapsedMs}ms)" (elapsedMs < 5000)

  -- Worker: 応答しないワーカーはタイムアウトで kill され、以後はエラー
  let slowWorkerPy :=
    "import sys, json, time
for line in sys.stdin:
    time.sleep(30)
    print(json.dumps({'late': True}), flush=True)"
  withWorker { exe := "python3", args := #["-c", slowWorkerPy] } fun w => do
    let timedOut ← try
      discard <| w.callJson (Lean.Json.mkObj []) (timeoutSec := 1)
      pure false
    catch _ => pure true
    check "Worker: 応答なしはタイムアウトで IO.userError" timedOut
    let failedAfter ← try
      discard <| w.callJson (Lean.Json.mkObj [])
      pure false
    catch _ => pure true
    check "Worker: タイムアウト後の呼び出しはエラー(kill 済み)" failedAfter

  -- Worker: EOF を無視するワーカーでも shutdown が固まらない(kill 保険)
  let stubbornPy :=
    "import sys, time
sys.stdin.read()
time.sleep(30)"
  let w ← Worker.spawn { exe := "python3", args := #["-c", stubbornPy] }
  let t0 ← IO.monoMsNow
  discard <| w.shutdown (timeoutSec := 1)
  let elapsedMs := (← IO.monoMsNow) - t0
  check s!"Worker: EOF 無視でも shutdown が戻る({elapsedMs}ms)" (elapsedMs < 5000)

  IO.println "スモークテスト全件成功"
