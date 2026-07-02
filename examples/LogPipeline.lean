import Shed

/-!
# 横断消費者: アクセスログ・ミニパイプライン

Web サーバーのアクセスログを素材に、shed のバッテリーを一気通貫で使う
小さな ETL。データエンジニアの日常作業(生ログ → パース → 集計 → 契約 →
配信確認)を Lean の型の内側で回す。

処理の流れと使用モジュール:

1. `Sys.Os.glob` — `examples/logs/*.log` を発見する
2. `Sys.Regex` — Common Log Format を名前付きグループでパース(不正行は警告して数える)
3. `Sys.Data` — DuckDB に `insertRows` で一括投入し、SQL で集計(パラメータ付き)、
   `queryAs` で型に回収
4. `Sys.Py` — 中央値の計算を Python に逃がし、Lean 側の計算と突き合わせる(オラクル)
5. `Pure.Contract` — 集計テーブルの契約を正本として定義し、
   実行時検証(許容値チェック)と成果物生成(schema.yml / JSON Schema)の両方に使う
6. `Sys.Subprocess` + `Sys.Http` — 生成した JSON Schema をローカル HTTP サーバーで
   配信し、GET で取り戻して正本と一致することを確認する(配信の往復検証)
7. `Sys.Log` — 全工程の進捗を stderr に流す(`SHED_LOG=debug` で INSERT も見える)

実行: `lake env lean --run examples/LogPipeline.lean [出力ディレクトリ]`
-/

open Shed.Pure.Contract
open Shed.Sys

def check (label : String) (cond : Bool) : IO Unit := do
  if cond then
    IO.println s!"ok: {label}"
  else
    throw <| IO.userError s!"NG: {label}"

-- ## 契約(正本)

/-- アクセスログ 1 行分の契約。実行時の許容値チェックと
schema.yml / JSON Schema の生成が、この一箇所から出る。 -/
def accessLogContract : Model := {
  name := "stg_access_log"
  description := "Web サーバーアクセスログの staging。生ログを正規化した1リクエスト=1行"
  columns := #[
    { name := "ip", type := .text, description := "クライアント IP" },
    { name := "method", type := .text,
      accepted := #["GET", "POST", "PUT", "DELETE"],
      description := "HTTP メソッド。増やすときは契約を先に変える" },
    { name := "path", type := .text },
    { name := "status", type := .integer },
    { name := "bytes", type := .integer, description := "応答サイズ。'-' は 0 と読む" }
  ]
}

-- ## パース

/-- パース済みの 1 リクエスト。 -/
structure LogRow where
  ip : String
  method : String
  path : String
  status : Nat
  bytes : Nat
  deriving Repr, Lean.ToJson

/-- Common Log Format(`%h %l %u [%t] "%r" %>s %b`)。 -/
def logPattern : String :=
  r#"^(?P<ip>\S+) \S+ \S+ \[(?P<ts>[^\]]+)\] "(?P<method>[A-Z]+) (?P<path>\S+)[^"]*" (?P<status>\d{3}) (?P<bytes>\d+|-)$"#

/-- 1 行をパースする(形式外の行は `none`)。 -/
def parseLine (re : Regex.Re) (line : String) : IO (Option LogRow) := do
  let some m ← re.find? logPattern line | return none
  let some ip := m.named? "ip" | return none
  let some method := m.named? "method" | return none
  let some path := m.named? "path" | return none
  let some status := (m.named? "status").bind (·.toNat?) | return none
  -- 応答サイズ "-"(本文なし)は 0 と読む
  let bytes := ((m.named? "bytes").bind (·.toNat?)).getD 0
  return some { ip, method, path, status, bytes }

-- ## 集計行の型(queryAs の契約)

structure StatusCount where
  status : Nat
  n : Nat
  deriving Lean.FromJson, Repr

structure MethodStat where
  method : String
  hits : Nat
  total_bytes : Nat
  deriving Lean.FromJson, Repr

structure PathHits where
  path : String
  hits : Nat
  deriving Lean.FromJson, Repr

def main (args : List String) : IO Unit := do
  -- Contracts.lean の生成物(examples/out/schema.yml)を上書きしないよう一段掘る
  let outDir : System.FilePath := args.headD "examples/out/access"
  Log.info "アクセスログ・パイプライン開始"

  -- 1. ログファイルの発見(隠しディレクトリは既定で歩かない)
  let files ← Os.glob "logs/*.log" (root := "examples")
  check "glob: ログファイルが 1 件見つかる" (files.size == 1)

  -- 2〜3. パース(常駐 re)と集計(常駐 DuckDB)— ブラケットをネストして両方を張る
  let (rows, malformed, statusCounts, methodStats, topPaths) ←
    Regex.withRe fun re => Data.withDuck fun db => do
      let mut rows : Array LogRow := #[]
      let mut malformed : Nat := 0
      for f in files do
        for line in (← IO.FS.lines f) do
          if line.trimAscii.isEmpty then
            continue
          match ← parseLine re line with
          | some r => rows := rows.push r
          | none =>
            malformed := malformed + 1
            Log.warn s!"パース不能行: {line}"
      Log.info s!"パース完了: {rows.size} 行(不正 {malformed} 行)"

      db.exec "create table access_log (
                 ip varchar, method varchar, path varchar, status int, bytes int)"
      -- 一括投入(1 行ずつの INSERT は 1 行 = 1 往復になるため)
      db.insertRows "access_log" (rows.map Lean.toJson)
      Log.debug s!"insertRows: {rows.size} 行を一括投入"

      -- 集計はすべて SQL、回収は FromJson の型検査つき
      let statusCounts ← db.queryAs StatusCount
        "select status, count(*)::int as n from access_log
         group by status order by n desc, status"
      let methodStats ← db.queryAs MethodStat
        "select method, count(*)::int as hits, sum(bytes)::int as total_bytes
         from access_log group by method order by hits desc, method"
      -- 値はプレースホルダで渡す(クォート安全)
      let topPaths ← db.queryAs PathHits
        "select path, count(*)::int as hits from access_log
         where status = ? group by path order by hits desc, path limit 3"
        #[Lean.toJson (200 : Nat)]
      pure (rows, malformed, statusCounts, methodStats, topPaths)

  check "パース: 23 行が形式に合致" (rows.size == 23)
  check "パース: 3 行が形式外" (malformed == 3)
  check "集計: ステータス別件数の合計がパース行数と一致"
    ((statusCounts.map (·.n)).foldl (· + ·) 0 == rows.size)
  check "集計: 最多ステータスは 200 が 14 件"
    (statusCounts[0]?.any fun c => c.status == 200 && c.n == 14)
  check "集計: メソッド別の合計もパース行数と一致"
    ((methodStats.map (·.hits)).foldl (· + ·) 0 == rows.size)
  check "集計: 200 のパス上位が取れる" (topPaths.size == 3)

  -- 4. Python をオラクルに: 応答サイズの中央値を両側で計算して突き合わせ
  let bytesArr := rows.map (·.bytes)
  let pyMedian : Nat ← Py.call "sorted(data)[len(data)//2]" bytesArr
  let leanMedian := (bytesArr.qsort (· < ·))[bytesArr.size / 2]!
  check s!"Py オラクル: 中央値が Lean 側と一致({pyMedian} bytes)"
    (pyMedian == leanMedian)

  -- 5. 契約の実行時利用: method 列の許容値でパース結果を検査
  let methodCol := accessLogContract.columns.find? (·.name == "method") |>.getD default
  check "契約: 全行の method が許容値の範囲内"
    (rows.all fun r => methodCol.accepted.contains r.method)

  -- 契約からの成果物生成(dbt schema.yml と JSON Schema)
  IO.FS.createDirAll outDir
  IO.FS.writeFile (outDir / "schema.yml")
    ((dbtSchema #[accessLogContract]).pretty ++ "\n")
  IO.FS.writeFile (outDir / "stg_access_log.schema.json")
    (accessLogContract.toJsonSchema.pretty ++ "\n")
  Log.info s!"契約の成果物を生成: {outDir}"

  -- 6. 配信の往復検証: 生成物を HTTP で配信し、GET で取り戻して正本と一致するか
  let serveCmd : Cmd := {
    exe := "python3"
    args := #["-m", "http.server", "18790", "--bind", "127.0.0.1",
              "--directory", outDir.toString] }
  let server ← serveCmd.spawn ⟨.null, .null, .null⟩
  try
    let mut up := false
    for _ in [0:50] do
      if !up then
        try
          let r ← Http.get "http://127.0.0.1:18790/" (timeoutSec := 2)
          if r.ok then up := true
        catch _ =>
          IO.sleep 100
    check "HTTP: 配信サーバーが起動した" up

    let r ← Http.get "http://127.0.0.1:18790/stg_access_log.schema.json"
    check "HTTP: 200 で取得できる" r.ok
    check "HTTP: 配信された JSON Schema が正本と一致"
      (r.json?.map (·.compress) == some accessLogContract.toJsonSchema.compress)
  finally
    server.kill
    discard server.wait

  -- 結果の表示
  IO.println ""
  IO.println "ステータス別:"
  for c in statusCounts do
    IO.println s!"  {c.status}  {c.n} 件"
  IO.println "メソッド別:"
  for m in methodStats do
    IO.println s!"  {m.method}  {m.hits} 件  {m.total_bytes} bytes"
  IO.println "200 のパス上位:"
  for p in topPaths do
    IO.println s!"  {p.path}  {p.hits} 件"
  IO.println ""
  Log.info "パイプライン完了"
  IO.println "アクセスログ・パイプライン全件成功"
