## BUG-5154 · manga-render-backfill-overwrites-script-edits
- **报告**：2026-11-22（PR #4031 HBK-AUDIT-016 复审时发现，同类隐患）
- **真实性**：✅ 源码确认（未跑运行时复现）。`fushi/lib/src/media/manga/audio/manga_audio_render_service.dart` 生成开始时 `mangaAudioScriptStoreFor(appModel).load(bookKey)` 读一份整稿（约第 95 行），合成跑完后 `save(job.bookKey, volume.script)`（约第 255 行，`keepCandidate` 第 355 行、声音指派第 466 行同理）把整份稿无条件写回。合成期间用户在制作台 / 逐句复核里改的说话人、念法等会被这份旧稿整份盖掉（复核页的修订校验只挡「复核拿旧稿盖别人」，挡不住「别人拿旧稿盖复核」）。
- **[ ] ① 未修复** — 方向：店加按卷排队的读改写 `update(bookKey, edit)`，生成回填只把回填行的 `audio` / `voice` / `say` 套到盘上最新稿，不整份写回持有的旧稿。
- **[ ] ② 未加自动化测试** — 应在店层测：回填期间另一会话 `saveIfCurrent` 改了别的行，回填落盘后两处改动都在。
- **备注**：与 BUG-5145 同根（整稿后写者胜）。
