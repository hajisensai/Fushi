## BUG-3894 · 音频源「连接被拒」被报成「无法解析 host」
- **报告**：2026-10-31（反馈 uY5I6JRU39 的日志，Android 3.0.0）
- **真实性**：✅ 真 bug（文案）。`fushi/lib/src/utils/misc/word_audio_resolver.dart` 原 :657 把任何 `SocketException` 都报成 `audio_source_dns_error`；用户日志全是 `Connection refused (errno 111), address = localhost`——解析成功，是手机上 localhost 没有服务在听，提示却把人引去查网络 / DNS。
- **[x] ① 已修复** — dc92af870d：抽 `describeAudioSourceFetchError`，按套接字错误种类分流：`Failed host lookup` → DNS 文案；errno 111/61/10061 → 新 key `audio_source_connection_refused`；其它套接字错误给系统消息。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/word_audio_connection_error_text_test.dart`。
- **备注**：反馈本身「悬浮球截图查词无发音」是配置问题（唯一报错的音源是 localhost），「没有查词历史」在当前代码路径（`floating_lyric_lookup_host.dart` → `pushNestedPopup` → `dictionary_page_mixin.dart` 有结果即写搜索 / 查词历史）上未能证实，用户是旧版 3.0.0，未改。
