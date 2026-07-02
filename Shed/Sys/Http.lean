import Shed.Sys.Subprocess

/-!
# Shed.Sys.Http — HTTP クライアント(requests 相当の8割)

curl サブプロセスの薄いラッパ。表層は `get` / `postJson` の単相 API。

- **デフォルト有界**: タイムアウト既定 30 秒。無限にしたければ明示的に
  大きな値を渡す(bounded-by-default 規約)
- リダイレクトは追う(requests と同じ既定)
- 認証などは `headers` で注入する(特定サービスの認証方式を
  shed に持ち込まない)

## 失敗モード

- 接続失敗・名前解決失敗・タイムアウト → `IO.userError`(curl の exit code 付き)
- HTTP エラーステータス(4xx/5xx)は**エラーにしない** — `Response.status` で
  判定する(requests と同じ)。`Response.ok` を見よ
- `Response.json` — 本文が JSON でなければ `Except.error`
-/

namespace Shed.Sys.Http

open Lean (Json)

/-- HTTP レスポンス。 -/
structure Response where
  status : Nat
  body : String
  deriving Repr, Inhabited

namespace Response

/-- 2xx かどうか。 -/
def ok (r : Response) : Bool :=
  200 ≤ r.status && r.status < 300

/-- 本文を JSON としてパースする(三段命名: Except 版)。 -/
def json (r : Response) : Except String Json :=
  Json.parse r.body

/-- 本文を JSON としてパースする(Option 版)。 -/
def json? (r : Response) : Option Json :=
  r.json.toOption

end Response

/-- curl の共通引数。`--write-out` でステータスコードを本文の後ろに付ける。 -/
private def curlCmd (url : String) (headers : Array (String × String))
    (timeoutSec : Nat) (extra : Array String) : Cmd :=
  { exe := "curl"
    args := #["-sS", "-L", "--max-time", toString timeoutSec,
              "--write-out", "\n%{http_code}"]
      ++ headers.flatMap (fun (k, v) => #["-H", s!"{k}: {v}"])
      ++ extra
      ++ #[url] }

/-- curl の出力(本文 + 改行 + ステータスコード)を分解する。 -/
private def parseOutput (out : IO.Process.Output) : IO Response := do
  if out.exitCode != 0 then
    throw <| IO.userError
      s!"Shed.Sys.Http: curl が exit code {out.exitCode} で失敗\n{out.stderr}"
  -- 出力は「本文 + '\n' + ステータスコード」。最後の行がステータス
  let lines := out.stdout.splitOn "\n"
  let statusStr := lines.getLastD ""
  let body := String.intercalate "\n" lines.dropLast
  match statusStr.trimAscii.toString.toNat? with
  | some status => pure { status, body }
  | none =>
    throw <| IO.userError s!"Shed.Sys.Http: ステータスコードが読めない: {statusStr}"

/-- curl 自身の `--max-time` が第一の境界。外側のサブプロセス打ち切りは
起動オーバーヘッド分の余裕を足した保険(`0` = 無制限はそのまま伝える)。 -/
private def outerTimeout (timeoutSec : Nat) : Nat :=
  if timeoutSec == 0 then 0 else timeoutSec + 10

/--
GET リクエスト。タイムアウト既定 30 秒、リダイレクト追従。
HTTP エラーステータスは例外にしない(`Response.ok` で判定する)。
-/
def get (url : String) (headers : Array (String × String) := #[])
    (timeoutSec : Nat := 30) : IO Response := do
  parseOutput (← callRaw (curlCmd url headers timeoutSec #[])
    (timeoutSec := outerTimeout timeoutSec))

/--
JSON を POST する。`Content-Type: application/json` は自動で付く。
-/
def postJson (url : String) (payload : Json)
    (headers : Array (String × String) := #[])
    (timeoutSec : Nat := 30) : IO Response := do
  let cmd := curlCmd url (#[("Content-Type", "application/json")] ++ headers)
    timeoutSec #["-X", "POST", "--data-binary", "@-"]
  parseOutput (← callRaw cmd payload.compress (timeoutSec := outerTimeout timeoutSec))

end Shed.Sys.Http
