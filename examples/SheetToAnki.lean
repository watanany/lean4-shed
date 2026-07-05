import Shed

/-!
# SheetToAnki — Google Sheets を正本にした Anki デッキの片方向同期

シート(リンク共有の CSV エクスポート)を取得し、ID 列をキーに AnkiConnect へ
upsert する。カードのスケジュール(間隔・期日・履歴)には一切触れない。
削除もしない — シートに無い ID は報告だけする。

## CI 非対応(手元検証専用の例)

この例は実 Anki の起動 + AnkiConnect アドオン + Google Sheets(または
ローカル CSV)を必要とするため、CI では実行しない(`.github/workflows/ci.yml`
の実行リストに載せない)。手元で動かすときは:

    lake env lean --run examples/SheetToAnki.lean

## 前提
- Anki が起動していて AnkiConnect アドオン(コード 2055492159)が入っていること
- シートが「リンクを知っている全員(閲覧者)」で共有されていること
  (「ウェブに公開」は不要。完全非公開のままにしたい場合は localCsvPath を使う)
- shed と同じ外部前提: curl(Sys.Http)、python3 + duckdb(Sys.Data)

## シート/ノートタイプの契約
- シート列(ヘッダ): ID, 表面, 裏面, 補足, ソース, tags
- Anki ノートタイプ: 第1フィールドが ID(照合キー)。フィールド名は
  日本語のまま(表面/裏面/補足/ソース)で、AnkiConnect には JSON 文字列として渡す
- Lean 側の構造体フィールドは ASCII(front/back/note/source/tags)。
  DuckDB の列別名も ASCII に寄せ、Lean の識別子に日本語を使わない

## 失敗モード
- 共有が「制限付き」のまま → Google がログイン HTML を 200 で返すため、
  本文先頭で検知して中断する
- 契約列が欠けている → DuckDB の select が落ち、Anki に触れる前に中断
- ノートタイプに対応フィールドが無い → notesInfo の解読で中断(書き込み前)
- Anki 未起動 / AnkiConnect 不達 → HTTP エラーで中断
-/

open Lean (Json)
open Shed.Sys

namespace SheetToAnki

/-! ## 設定 -/

/-- シートの CSV エクスポート URL。ファイル ID は URL の `/d/` と `/edit` の間。
これを空文字にして localCsvPath を設定すると、完全非公開のまま使える。 -/
def sheetCsvUrl : String :=
  "https://docs.google.com/spreadsheets/d/<ファイルID>/export?format=csv&gid=0"

/-- sheetCsvUrl が空のときに読むローカル CSV のパス。 -/
def localCsvPath : String := ""

/-- AnkiConnect のエンドポイント。 -/
def ankiConnectUrl : String := "http://127.0.0.1:8765"

/-- 取り込み先デッキ名。 -/
def deckName : String := "Default"

/-- 第1フィールドが ID のノートタイプ名。 -/
def notetypeName : String := "基本+補足"

/-- CSV 列名・Anki フィールド名・DuckDB 別名(ASCII)の対応。
1 か所に集約し、Lean の識別子には日本語を使わず値として持つ。
(csv列名, ankiフィールド名, duckdb別名) -/
def fieldEntries : List (String × String × String) :=
  [ ("ID",   "ID",   "id")
  , ("表面", "表面", "front")
  , ("裏面", "裏面", "back")
  , ("補足", "補足", "note")
  , ("ソース", "ソース", "source") ]

/-! ## Pure 層 — 契約型と差分計画 -/

/-- シートの 1 行(契約の正本)。フィールド名は ASCII。 -/
structure Row where
  id : String
  front : String
  back : String
  note : String
  source : String
  tags : String
  deriving Lean.FromJson, Repr, Inhabited

/-- 空白区切りのタグ文字列をリストにする(連続空白は無視)。 -/
def tagListOf (s : String) : List String :=
  (s.splitOn " ").filter (!·.isEmpty)

/-- タグ集合として等しいか(順序・重複は無視)。 -/
def sameTags (a b : List String) : Bool :=
  a.all b.contains && b.all a.contains

#guard tagListOf "日常 言語::フランス語  料理" == ["日常", "言語::フランス語", "料理"]
#guard sameTags (tagListOf "a b") (tagListOf "b a")
#guard !sameTags (tagListOf "a") (tagListOf "a b")

/-- ID 以外の内容が等しいか(タグは集合比較)。 -/
def sameContent (a b : Row) : Bool :=
  a.front == b.front && a.back == b.back && a.note == b.note
    && a.source == b.source && sameTags (tagListOf a.tags) (tagListOf b.tags)

/-- Anki 側に既に存在するノート。noteId は精度を落とさないよう
JSON のまま素通しする(64bit を超えるエポックミリ秒 ID 対策)。 -/
structure ExistingNote where
  noteId : Json
  row : Row

/-- 差分計画。適用(Sys)と計画(Pure)を分けるための値。 -/
structure Plan where
  toAdd : Array Row
  toUpdate : Array (Json × Row)
  unchanged : Nat
  orphanIds : Array String

/-- シートと Anki の現状から差分計画を立てる。削除は計画しない
(orphanIds として報告するだけ)。 -/
def plan (rows : Array Row) (existing : Array ExistingNote) : Plan := Id.run do
  let mut toAdd : Array Row := #[]
  let mut toUpdate : Array (Json × Row) := #[]
  let mut unchanged := 0
  for r in rows do
    match existing.find? (·.row.id == r.id) with
    | some e =>
      if sameContent e.row r then unchanged := unchanged + 1
      else toUpdate := toUpdate.push (e.noteId, r)
    | none => toAdd := toAdd.push r
  let sheetIds := rows.map (·.id)
  let orphanIds := existing.filterMap fun e =>
    if sheetIds.contains e.row.id then none else some e.row.id
  return { toAdd, toUpdate, unchanged, orphanIds }

/-- AnkiConnect の fields オブジェクト(tags は含めない)。
Anki フィールド名(日本語)を fieldEntries から引いてキーにする。 -/
def Row.fieldsJson (r : Row) : Json :=
  let get (alias_ : String) : String :=
    match alias_ with
    | "id" => r.id | "front" => r.front | "back" => r.back
    | "note" => r.note | "source" => r.source | _ => ""
  Json.mkObj <| fieldEntries.map fun (_, ankiName, alias_) =>
    (ankiName, Json.str (get alias_))

/-- AnkiConnect の tags 配列。 -/
def Row.tagsJson (r : Row) : Json :=
  Json.arr ((tagListOf r.tags).toArray.map Json.str)

/-! ## Sys 層 — SQL 生成 -/

/-- 契約列を ASCII 別名で取り出す SQL。空セル(NULL)は '' に潰す
(queryAs の String 検証が null で落ちるのを防ぐ)。列が欠けていれば
DuckDB がここで落ちる(Anki に触れる前)。識別子/リテラルのクォートは
本体の `Data.sqlIdent` / `Data.sqlStr` を使う。 -/
def selectSql : String :=
  let col (csv alias_ : String) : String :=
    "coalesce(" ++ Data.sqlIdent csv ++ ", '') as " ++ Data.sqlIdent alias_
  let cols := fieldEntries.map (fun (csv, _, alias_) => col csv alias_)
              ++ [col "tags" "tags"]
  let idCol := Data.sqlIdent "ID"
  "select " ++ String.intercalate ", " cols
    ++ " from cards where coalesce(" ++ idCol ++ ", '') <> ''"

/-! ## Sys 層 — シート取得と CSV 解読 -/

/-- CSV 本文を DuckDB に読ませ、契約型 Row の配列にする
(CSV パーサは書かない — エンジンの運転)。 -/
def loadRows (csvBody : String) : IO (Array Row) :=
  IO.FS.withTempFile fun h path => do
    h.putStr csvBody
    h.flush
    Data.withDuck fun db => do
      let file := Data.sqlStr path.toString
      db.exec s!"create table cards as select * from read_csv({file}, header = true, all_varchar = true)"
      db.queryAs Row selectSql

/-! ## Sys 層 — AnkiConnect -/

/-- AnkiConnect を 1 回呼ぶ。error が非 null なら例外にする。 -/
def invoke (action : String) (params : Json := Json.mkObj []) : IO Json := do
  let payload := Json.mkObj
    [ ("action", Json.str action)
    , ("version", Lean.toJson (6 : Nat))
    , ("params", params) ]
  let r ← Http.postJson ankiConnectUrl payload
  unless r.ok do
    throw <| IO.userError s!"AnkiConnect: HTTP {r.status}。Anki は起動しているか。"
  let j ← IO.ofExcept r.json
  match j.getObjVal? "error" with
  | .ok .null => pure ()
  | .ok e => throw <| IO.userError s!"AnkiConnect {action}: {e.compress}"
  | .error _ => pure ()
  IO.ofExcept (j.getObjVal? "result")

/-- notesInfo の 1 要素を ExistingNote に解読する。
Anki フィールド名(日本語)を fieldEntries から引いて読む。 -/
def decodeNote (j : Json) : Except String ExistingNote := do
  let noteId ← j.getObjVal? "noteId"
  let tagsArr ← (← j.getObjVal? "tags").getArr?
  let tagList ← tagsArr.toList.mapM (·.getStr?)
  let fields ← j.getObjVal? "fields"
  let f (ankiName : String) : Except String String := do
    (← (← fields.getObjVal? ankiName).getObjVal? "value").getStr?
  let byAlias (alias_ : String) : Except String String :=
    match fieldEntries.find? (fun (_, _, a) => a == alias_) with
    | some (_, ankiName, _) => f ankiName
    | none => .error s!"fieldEntries に別名がない: {alias_}"
  let row : Row :=
    { id := ← byAlias "id", front := ← byAlias "front", back := ← byAlias "back"
    , note := ← byAlias "note", source := ← byAlias "source"
    , tags := String.intercalate " " tagList }
  return { noteId, row }

/-- 対象デッキ × ノートタイプの既存ノートを全件取得する。
Anki の検索構文は SQL ではないので、名前は `"…"` で囲む。 -/
def fetchExisting : IO (Array ExistingNote) := do
  let ankiQuery := s!"deck:\"{deckName}\" note:\"{notetypeName}\""
  let ids ← invoke "findNotes" (Json.mkObj [("query", Json.str ankiQuery)])
  let infos ← invoke "notesInfo" (Json.mkObj [("notes", ids)])
  let arr ← IO.ofExcept infos.getArr?
  arr.mapM fun j => IO.ofExcept (decodeNote j)

/-- 既存ノートのフィールドとタグを上書きする(スケジュールは無傷)。 -/
def updateNote (noteId : Json) (r : Row) : IO Unit :=
  discard <| invoke "updateNote" <| Json.mkObj
    [ ("note", Json.mkObj
        [ ("id", noteId), ("fields", r.fieldsJson), ("tags", r.tagsJson) ]) ]

/-- 新規ノートを追加する。 -/
def addNote (r : Row) : IO Unit :=
  discard <| invoke "addNote" <| Json.mkObj
    [ ("note", Json.mkObj
        [ ("deckName", Json.str deckName)
        , ("modelName", Json.str notetypeName)
        , ("fields", r.fieldsJson)
        , ("tags", r.tagsJson)
        , ("options", Json.mkObj [("allowDuplicate", Json.bool false)]) ]) ]

/-! ## エントリポイント -/

/-- CSV 本文を取得する(URL 優先、無ければローカル)。 -/
def fetchCsv : IO String := do
  if !sheetCsvUrl.isEmpty then
    let r ← Http.get sheetCsvUrl
    unless r.ok do
      throw <| IO.userError
        s!"シート取得に失敗: HTTP {r.status}。共有設定(リンクを知っている全員・閲覧者)を確認。"
    if r.body.startsWith "<" then
      throw <| IO.userError "応答が HTML(共有が「制限付き」の可能性)。中断する。"
    pure r.body
  else if !localCsvPath.isEmpty then
    IO.FS.readFile localCsvPath
  else
    throw <| IO.userError "sheetCsvUrl か localCsvPath のどちらかを設定すること。"

/-- 取得 → 解読 → 計画(Pure) → 適用 → 報告。 -/
def run : IO Unit := do
  let body ← fetchCsv
  let rows ← loadRows body
  if rows.isEmpty then
    throw <| IO.userError "CSV に行がない。中断する。"
  let existing ← fetchExisting
  let p := plan rows existing
  for (noteId, row) in p.toUpdate do updateNote noteId row
  for row in p.toAdd do addNote row
  IO.println s!"追加 {p.toAdd.size} / 更新 {p.toUpdate.size} / 変更なし {p.unchanged}"
  unless p.orphanIds.isEmpty do
    IO.println s!"シートに無いカード(削除するなら Anki 側で手動): ID = {String.intercalate ", " p.orphanIds.toList}"

end SheetToAnki

def main : IO Unit := SheetToAnki.run
