## BUG-2386 · 有声书扩展例句后字幕原句字段仍只收录当前句
- **报告**：2026-09-09（用户转述定力：添加上一句后卡片仅有当前句，音频却包含上一句）
- **真实性**：✅ 真 bug（条件性代码路径已确认）。`fushi/lib/src/pages/implementations/reader_fushi/mining.part.dart:27` 合并例句，`:50` 原先只快照当前 cue，`:180` 附近将其传给 Anki；映射为 `{cue-sentence}` 时，`packages/fushi_anki/lib/src/anki_models.dart:976` 优先渲染该单句，音频却来自扩展草稿。默认 Lapis 使用 `{sentence}`，尚未取得报告者实际映射，不能断言已复现其设备问题。
- **[x] ① 已修复** — `e6786db37a`：有上下文草稿时，cue 文本快照使用已合并例句；无草稿时保留原 cue 全文。快照仍在音频导出的首个 await 前完成，新建与覆盖共用此路径。
- **[x] ② 已加自动化测试** — `fushi/test/pages/sentence_draft_wiring_guard_test.dart` 新增扩展 cue 文本与异步快照接线守卫；与视频接线、草稿文本/音频合并、reader race/audio 守卫共 55 项通过。`flutter analyze --no-pub` 全量通过。
- **备注**：未完成用户设备上的真实制卡复测，未运行全量测试及平台构建。测试辅助工具首轮 PDFium 下载超时，配置本机代理后恢复；formatter 改动无关区域导致的两项接线守卫失败已通过收回无关格式变更解决，最终 55 项退出码 0。视频已合并两种文本；本次只修有声书/阅读器确定的字段不一致，不修改 Galgame。
