## BUG-1684 · 对外 User-Agent 仍报旧名 Hibiki
- **报告**：2026-08-16（用户：「api等ua没换成fushi」）
- **真实性**：✅ 真 bug。改名批次漏了 4 处**以自己身份**对外报的 UA：
  `fushi/lib/src/media/video/subtitle/open_subtitles_client.dart:20`（默认 `Hibiki v1`，
  且 `fromJson` 同一字面量）、
  `fushi/lib/src/pages/implementations/video_external_provider_settings_section.dart:971`
  （设置页草稿默认值）、
  `fushi/lib/src/media/video/video_shader_downloader.dart:344,491`、
  `fushi/lib/src/pages/implementations/custom_fonts_page.dart:916`。
  对外部服务而言 UA 就是这个 app 的身份，两个名字同时在跑 = 同一个客户端有两个身份。
- **[x] ① 已修复** — `b8d5a54b3c`。收敛成单一真相源
  `fushi/lib/src/utils/net/app_user_agent.dart` 的 `fushiUserAgent(<组件名>)`。
  OpenSubtitles 的 UA 被序列化进 `video_subtitle_opensubtitles_config` 偏好，光改构造
  默认值改不动已落盘的那一份，故解码时把**恰好等于旧默认值**的归一到新默认值，
  用户自填的 UA 原样保留。故意伪装成浏览器的三处（Aidoku 过 WAF、Google Lens OCR、
  YouTube 分离流回放 UA 必须与铸造 URL 时逐字一致）是「装成别人」不是「报自己」，
  保持原样。
- **[x] ② 已加自动化测试** — `fushi/test/tools/outbound_user_agent_guard_test.dart`
  （全树扫 `lib/`，带 `User-Agent`/`userAgent` 的行不得含旧名；浏览器伪装文件白名单）。
  守卫做过变异实测：第一版正则漏了 `'User-Agent':` 的收尾引号，把 UA 改回 Hibiki
  仍然绿，已修正后复测为红、还原后字节哈希一致。
- **备注**：qBittorrent 分类的旧名残留另见 BUG-1687（不是 UA，且不能静默改写）。
