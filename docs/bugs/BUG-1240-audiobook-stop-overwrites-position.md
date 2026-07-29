## BUG-1240 · 有声书退出停止后位置被零覆盖
- **报告**：2026-07-29（用户）
- **真实性**：✅ 真 bug。reader pop 先 `flushPosition()` 保存正确位置，随后 `AudiobookSession.stop()` 调 `stopPlayback()`；旧实现先执行 just_audio `stop()`（position 归零），再 `_maybeSavePosition(force:true)`，把数据库重新覆盖成 0。
- **[x] ① 已修复** — `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart` 的 `stopPlayback()` 改为先 `await flushPosition()`，再停止主/clip 播放器；停止后不再采样位置。
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/audiobook_position_flush_test.dart` 覆盖 65 秒恢复位 stop 后仍写 65 秒，并用源码顺序守卫钉死 flush 早于两个 stop、stop 后无 force-save。
- **备注**：本轮按用户要求不等待完整编译/设备验收。
