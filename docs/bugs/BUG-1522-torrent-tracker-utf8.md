## BUG-1522 · Tracker detail JSON rejects localized backend errors
- **报告**：2026-08-11（用户：）
- **真实性**：✅ 真 bug。`native/fushi_torrent/fushi_torrent_ffi.cpp:59` 的共享 JSON 转义器把所有非 ASCII 字节原样输出，但 `ht_torrent_trackers` 会写入 WinSock/libtorrent 本地化的 `error_code::message()`；其字节不保证为 UTF-8。`packages/fushi_torrent/lib/src/embedded_torrent_engine.dart:169` 随后按严格 UTF-8 解码，任一非法字节都会让整包 Tracker JSON 变成 `null`，界面因而显示“加载出错”。
- **[x] ① 已修复** — 原生共享 JSON 出口现在先完整校验 UTF-8（含过长编码、代理项和越界码点），Windows 本地代码页消息依据 `GetLocaleInfoEx(LOCALE_IDEFAULTANSICODEPAGE)` 返回的用户区域 ANSI 代码页，经 `MultiByteToWideChar` / `WideCharToMultiByte(CP_UTF8)` 转成 UTF-8，转换仍失败才以 U+FFFD 兜底；Dart ABI 消费端对已随旧包分发的 DLL 使用同样的区域代码页转换，不再只显示替换字符。不能使用 `CP_ACP`：用户机器的系统活动代码页是 65001，但 libtorrent 返回的中文错误实际为 CP936。
- **[x] ② 已加自动化测试** — `packages/fushi_torrent/test/native_json_test.dart` 用包含 CP936“中文”字节的有效 Tracker JSON 验证 Windows 上内容被准确还原且整包不会被丢弃；`fushi/test/media/torrent/torrent_json_utf8_guard_test.dart` 钉住原生统一出口的 UTF-8 校验和 Windows 代码页转换约束。
- **备注**：按用户要求跳过自动化测试；用 Windows Debug 构建直接实测。
