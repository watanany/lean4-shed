import Std.Time

/-!
# Shed.Sys.Log — 最小のロガー

ISO 8601 タイムスタンプ + レベルつきで stderr に 1 行出す。それだけ。
出力先の切り替え・構造化ログ・ローテーションはやらない(必要になってから)。

しきい値は環境変数 `SHED_LOG`(`debug` / `info` / `warn` / `error`)で
プロセス起動時に決まる。既定は `info`。

```
Log.info "取り込み開始"
Log.warn s!"リトライ {n} 回目"
```
-/

namespace Shed.Sys.Log

/-- ログレベル。 -/
inductive Level where
  | debug
  | info
  | warn
  | error
  deriving Repr, BEq, Inhabited

def Level.rank : Level → Nat
  | .debug => 0
  | .info => 1
  | .warn => 2
  | .error => 3

def Level.name : Level → String
  | .debug => "DEBUG"
  | .info => "INFO"
  | .warn => "WARN"
  | .error => "ERROR"

def Level.ofString? : String → Option Level
  | "debug" => some .debug
  | "info" => some .info
  | "warn" => some .warn
  | "error" => some .error
  | _ => none

-- example: しきい値の順序
#guard Level.debug.rank < Level.info.rank && Level.warn.rank < Level.error.rank

/-- プロセス起動時に `SHED_LOG` から決まるしきい値。 -/
initialize minLevel : Level ← do
  let env ← IO.getEnv "SHED_LOG"
  pure <| (env.bind Level.ofString?).getD .info

/-- しきい値以上なら stderr に 1 行出す。 -/
def log (lvl : Level) (msg : String) : IO Unit := do
  if minLevel.rank ≤ lvl.rank then
    let now ← Std.Time.PlainDateTime.now
    IO.eprintln s!"{now} [{lvl.name}] {msg}"

def debug (msg : String) : IO Unit := log .debug msg
def info (msg : String) : IO Unit := log .info msg
def warn (msg : String) : IO Unit := log .warn msg
def error (msg : String) : IO Unit := log .error msg

end Shed.Sys.Log
