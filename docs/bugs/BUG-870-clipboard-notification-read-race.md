## BUG-870 · Luna 剪贴板变化被通知/读取竞态漏掉
- **报告**：2026-07-18（用户：LunaTranslator 已显示新句，但 Hibiki 偶尔仍停在旧句）
- **真实性**：✅ 真 bug。`hibiki/lib/src/sync/desktop_lookup_service.dart:318` 的 native 通知不携带通知时的文本；旧实现为每个通知并发读取当前剪贴板，快速连续通知可能全部读到最终值。`hibiki/lib/src/sync/desktop_lookup_service.dart:556` 原先只重试约 100ms，Luna 较长时间占用 `OpenClipboard` 时唯一通知会被直接丢弃；缓存的窗口 focus 也可能把实际来自前台游戏的写入误判成 Hibiki 自产。
- **[x] ① 已修复** — 通知统一进入串行 drain（`hibiki/lib/src/sync/desktop_lookup_service.dart:388`），每轮重新核对真实前台窗口并延长有界退避；Windows 同时轮询 `GetClipboardSequenceNumber`（`hibiki/lib/src/sync/desktop_lookup_service.dart:368`），在 native 通知漏发或本轮读取失败时补收最新变化。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/desktop_lookup_service_test.dart` 覆盖旧 100ms 窗口外才可读、连续通知串行读取、focus 缓存过期和 sequence polling 漏通知恢复；`hibiki/test/pages/home_dictionary_clipboard_watcher_breakpoint_test.dart` 继续守住页面断点重建时 watcher 生命周期。
- **备注**：仍需用 LunaTranslator + 实际游戏连续推进多句，确认日志中每次剪贴板 sequence 均被接收且页面不再停在旧句。
