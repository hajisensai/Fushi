## BUG-483 · 有声书整文件夹导入音频排序乱(全角/汉数字/零填充)
- **报告**：2026-06-30（用户：）
- **真实性**：✅ 真 bug — 根因 `packages/hibiki_audio/lib/src/audiobook/audio_file_sort.dart:1` 的 `_chunkPattern = RegExp(r'(\d+|\D+)')`。Dart `\d` 无 `unicode: true` 时只匹配 ASCII [0-9]，日文有声书常见的全角数字 `第０１話`、零填充不一致 落进 `\D+` 块走码元字典序，与肉眼数值顺序不符（如 `第１０話` 排到 `第２話` 前；多目录多选时目录前缀又干扰）。
- **[x] ① 已修复** — 提交 <PENDING> · `packages/hibiki_audio/lib/src/audiobook/audio_file_sort.dart`：①切块正则加 `unicode: true`；②比较前 `_normalizeDigits` 把全角 `０-９`(U+FF10..U+FF19)归一为 ASCII `0-9`，让全角/半角统一进数字块、消零填充差异；③先按 `_baseName`(去 `/` 或 `\` 目录前缀)比较再退全路径，消除跨目录多选的前缀干扰。纯函数签名 `compareAudioFilePath(String, String)` 不变(book_import_dialog/audiobook_import_dialog 不受影响)。
- **[x] ② 已加自动化测试** — `packages/hibiki_audio/test/audiobook/audio_file_sort_test.dart`：新增全角 `第０１話/第２話/第１０話`、零填充 `ep01/ep2/ep10`、跨目录前缀、全角+半角混排 4 组用例断言数值序；撤修复（恢复旧正则）实测 3 用例转红。
- **备注**：只修 1031(c) 排序；1031(a)(b) 整文件夹聚合/多选语义未动。analyze=No issues found!，audio_file_sort 测试 5/5 绿。
