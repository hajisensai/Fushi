## BUG-3931 · 复习卡原生声调图给低拍画下划线，与模板记法不一致
- **报告**：2026-11-01（用户：应用内反馈 kP5GJ0pahv）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/srs/srs_fushi_card_view.dart` `SrsPitchGraph` 给低拍画下边框、降调画整高竖线，与导出模板 `drawPitch` / `.fc-mora*`（只画高拍上划线 + 短降调符）不是一套记法，平板型 / 中高型被读成上下框。
- **[x] ① 已修复** — 784d4e96c2（`srsPitchMoraMarks` + CustomPainter，与模板同记法，尾高型虚线尾拍）
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_fushi_card_view_test.dart`「声调图逐拍画法与模板一致」
- **备注**：若反馈人指的是别的错误（例如声调号本身错）需追问；未在 Android 真机复测。
