## BUG-876 · Galgame 捕获文本缺少 Luna 风格线程选择
- **报告**：2026-07-19（用户：）
- **真实性**：✅ 真 bug。Luna 的 Output ABI 已提供 `hookcode / hookname / ThreadParam`，但 `native/galgame_voice_hook/injector/injector_main.cpp:278` 旧写入函数只把文本、序号和时间戳放进文本环；`hibiki/windows/runner/flutter_window.cpp:1629` 与 `hibiki/lib/src/mining/galgame_audio_source.dart:530` 也只传/解析 `seq / ts / text`，不同 Hook 线程因此不可区分，只能混进同一列表。
- **[x] ① 已修复** — IPC 升到 v6，文本槽保存稳定线程 id、ThreadParam、Hook 名称和 Hook code；Windows runner 与 Dart 全链路透传。捕获页新增 Luna 风格文本线程选择器；选择结果通过共享 header 回传 injector，手动选择优先于自动赢家，同时仍强制过滤重复伪影。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/galgame_audio_test.dart` 覆盖 native map 解析及选择/重置 MethodChannel；`hibiki/test/sync/texthooker_service_test.dart` 覆盖线程聚合与过滤；`hibiki/test/pages/texthooker_page_test.dart` 覆盖下拉选择后只显示指定线程。x64/x86 helper 均完成 Debug 编译并通过 CTest。
- **备注**：Thread id 使用 Luna ThreadParam + hookcode + hookname 的 FNV-1a 64 位哈希；0 保留为“自动选择”。
