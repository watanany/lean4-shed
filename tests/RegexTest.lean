import Shed.Sys.Regex

/-!
# Shed.Sys.Regex のテスト

PCRE 級の機能(先読み・後読み・後方参照・名前付きグループ)が
実際に動くことを確認する。実行: `lake env lean --run tests/RegexTest.lean`
-/

open Shed.Sys Shed.Sys.Regex

def check (label : String) (cond : Bool) : IO Unit := do
  if cond then
    IO.println s!"ok: {label}"
  else
    throw <| IO.userError s!"NG: {label}"

def main : IO Unit := do
  withRe fun re => do
    -- 基本
    check "test: 日付パターン" (← re.test "\\d{4}-\\d{2}-\\d{2}" "date: 2026-07-02")
    check "test: 不一致" (!(← re.test "^\\d+$" "abc"))

    -- キャプチャ(番号つき・名前付き)
    let m ← re.find? "(?P<user>\\w+)@(\\w+)" "mail: taro@example done"
    check "find?: マッチ本体" (m.any (·.matched == "taro@example"))
    check "find?: 番号つきグループ"
      (m.any (·.groups == #[some "taro", some "example"]))
    check "find?: 名前付きグループ"
      (m.any (·.named.contains ("user", some "taro")))

    -- 先読み・後読み(正規言語の外 = PCRE 級の証明)
    check "先読み: 円記号なしの金額のみ"
      (← re.test "\\d+(?= *円)" "3000 円")
    check "否定先読み" (!(← re.test "^foo(?!bar)" "foobar"))
    check "後読み" ((← re.find? "(?<=@)\\w+" "taro@example").any (·.matched == "example"))

    -- 後方参照
    check "後方参照: 重複語の検出" (← re.test "(\\w+) \\1" "デブリ デブリ 回収")
    check "後方参照: 非重複は不一致" (!(← re.test "(\\w+) \\1" "甲 乙"))

    -- 置換(グループ参照つき)・分割
    let s ← re.replace "(\\w+)@(\\w+)" "taro@example" "\\2/\\1"
    check "replace: グループ参照" (s == "example/taro")
    let parts ← re.split "\\s*[,、]\\s*" "a, b、c ,d"
    check "split: 区切りの正規化" (parts == #["a", "b", "c", "d"])

    -- フラグ
    check "ignoreCase" (← re.test "lean" "LEAN 4" { ignoreCase := true })
    check "dotAll" (← re.test "a.b" "a\nb" { dotAll := true })

    -- findAll
    let ms ← re.findAll "\\d+" "1 と 22 と 333"
    check "findAll: 全マッチ" (ms.map (·.matched) == #["1", "22", "333"])

    -- 不正パターンは位置情報つきエラー
    let failed ← try
      discard <| re.test "(" "x"
      pure false
    catch e => pure (toString e |>.startsWith "Shed.Sys.Regex")
    check "不正パターンは IO.userError" failed

  IO.println "Regex テスト全件成功"
