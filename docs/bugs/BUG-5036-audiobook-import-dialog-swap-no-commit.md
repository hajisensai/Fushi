## BUG-5036 · 应用内「附加 / 换有声书」对话框换音频不带 commit，旧音频在写库前就删了
- **报告**：2026-11-20（路线图 #3722 c13 遗留，归 c48）
- **真实性**：✅ 真 bug。
  - 根因：`fushi/lib/src/media/audiobook/audiobook_import_dialog.dart`（develop 上第 923 行）调 `AudiobookStorage.syncAudioFiles` 不传 `commit`，按其契约（BUG-4810）新文件落位后旧音频立刻删除，随后才 `ensureAudiobook` / `replaceAlignment` / `replaceAudio` 逐条写库：写库任一步失败时旧音频已经没了、库里还指着它们；字幕两列与音频两列也不在一个事务里，可能只换掉一半。
- **[x] ① 已修复** — 建行 + 字幕两列 + 音频两列收进 `commitAudiobookImportRow`（一个事务），作为 `syncAudioFiles` 的 `commit` 跑：写库成立后旧音频才删除，抛错则磁盘与库一起停在换之前。TTS 制作的 runner（`tts_render_runner.dart`）同病，但该文件有在途 PR #3794，未在本 PR 动。
- **[x] ② 已增加自动化测试** — `fushi/test/media/audiobook/audiobook_import_commit_test.dart`：Drift 拦截器让 `audiobooks` 音频列写入抛错，断言旧音频仍在原名、行上的音频与字幕都停在换之前；另钉对话框的 `syncAudioFiles` 调用带 `commit` 且音频列只在 commit 里写。
- **备注**：真机未复测（本轮所有者定不做设备验证）。
