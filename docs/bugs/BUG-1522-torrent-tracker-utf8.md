## BUG-1522 · Tracker detail JSON rejects localized backend errors
- **报告**：2026-08-11（用户：）
- **真实性**：✅ 真 bug。`native/fushi_torrent/fushi_torrent_ffi.cpp:59` 的共享 JSON 转义器把所有非 ASCII 字节原样输出，但 `ht_torrent_trackers` 会写入 WinSock/libtorrent 本地化的 `error_code::message()`；其字节不保证为 UTF-8。`packages/fushi_torrent/lib/src/embedded_torrent_engine.dart:169` 随后按严格 UTF-8 解码，任一非法字节都会让整包 Tracker JSON 变成 `null`，界面因而显示“加载出错”。
- **[x] ① 已修复** — 原生共享 JSON 出口现在完整校验 UTF-8（含过长编码、代理项和越界码点）并以 U+FFFD 替换非法序列；Dart ABI 消费端同时兼容已随旧包分发的 DLL，只替换非法文本字节后继续解析结构化 Tracker 数据。
- **[x] ② 已加自动化测试** — `packages/fushi_torrent/test/native_json_test.dart` 用包含 CP936 字节的有效 Tracker JSON 验证整包不会被丢弃；`fushi/test/media/torrent/torrent_json_utf8_guard_test.dart` 钉住原生统一出口的 UTF-8 校验约束。
- **备注**：按用户要求跳过自动化测试；用 Windows Debug 构建直接实测。
