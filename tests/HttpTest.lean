import Shed.Sys.Http

/-!
# Shed.Sys.Http のテスト

外部ネットワークに依存しないよう、ローカルに Python のテストサーバーを
立てて 127.0.0.1 相手に検証する。

実行: `lake env lean --run tests/HttpTest.lean`
-/

open Shed.Sys Shed.Sys.Http

def check (label : String) (cond : Bool) : IO Unit := do
  if cond then
    IO.println s!"ok: {label}"
  else
    throw <| IO.userError s!"NG: {label}"

/-- GET には固定 JSON、POST には本文をそのまま echo する HTTP サーバー。 -/
def serverPy : String := "
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def _send(self, code, body):
        data = body.encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path == '/notfound':
            self._send(404, json.dumps({'error': 'not found'}))
        else:
            self._send(200, json.dumps({'hello': 'shed', 'auth': self.headers.get('X-Token')}))
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        self._send(200, self.rfile.read(n).decode())

HTTPServer(('127.0.0.1', 18734), H).serve_forever()
"

def main : IO Unit := do
  -- テストサーバーを起動(stderr は inherit、テスト終了時に kill)
  let server ← (Cmd.spawn { exe := "python3", args := #["-c", serverPy] })
    ⟨.null, .null, .inherit⟩
  try
    -- サーバーの起動待ち(最大 5 秒、失敗したらリトライ)
    let mut up := false
    for _ in [0:50] do
      if !up then
        try
          let r ← get "http://127.0.0.1:18734/" (timeoutSec := 2)
          if r.status == 200 then up := true
        catch _ =>
          IO.sleep 100
    check "テストサーバーが起動した" up

    -- GET
    let r ← get "http://127.0.0.1:18734/"
    check "get: 200" (r.status == 200)
    check "get: ok" r.ok
    check "get: JSON 本文" (r.json?.any (·.getObjValD "hello" == Lean.Json.str "shed"))

    -- ヘッダ注入
    let r ← get "http://127.0.0.1:18734/" (headers := #[("X-Token", "secret")])
    check "get: ヘッダが届く" (r.json?.any (·.getObjValD "auth" == Lean.Json.str "secret"))

    -- 4xx はエラーにしない(requests と同じ)
    let r ← get "http://127.0.0.1:18734/notfound"
    check "get: 404 は例外ではなく status で返る" (r.status == 404 && !r.ok)

    -- POST(echo back)
    let payload := Lean.Json.mkObj [("n", (42 : Nat)), ("s", Lean.Json.str "値")]
    let r ← postJson "http://127.0.0.1:18734/echo" payload
    check "postJson: 200" (r.status == 200)
    check "postJson: 本文が往復する"
      (r.json?.any fun j => (j.getObjValD "n").getNat?.toOption == some 42)

    -- タイムアウト(存在しない到達不能アドレスに 1 秒)
    let timedOut ← try
      discard <| get "http://10.255.255.1:9/" (timeoutSec := 1)
      pure false
    catch _ => pure true
    check "get: タイムアウトは IO.userError" timedOut

    IO.println "HTTP テスト全件成功"
  finally
    server.kill
    discard server.wait
