## BUG-3418 · 从 Anki 卡片跳回视频提示「此设备没有对应来源」，但互联 host / 服务端上有
- **报告**：2026-10-12（反馈 #gCk38gT_xu，Android；截图 toast「此设备没有对应来源，请先导入或下载作品。」，库里是 host 的远端占位卡）
- **真实性**：✅ 属实（由代码路径推断，反馈无复现步骤、日志无相关行）。来源链接只会在有本地文件的设备上生成（`fushi/lib/src/pages/implementations/video_fushi/lookup_mining.part.dart:523` `resolveSourceLink` 对远端流返回 null），uid 是那台设备库里的 `bookUid`；卡片在电脑 / 服务端制、在手机上点回跳时，`fushi/lib/src/anki/card_source_router.dart`（修复前 :59-70）只查本机 `VideoBookRow`，本机只有远端占位 -> 误报「没有对应来源」。远端视频的 id 就是 host 的 `bookUid`，与链接 uid 同键。
- **[x] ① 已修复** — 本地库没有时去已配对互联 host 的清单（经共享 `RemoteLibraryCache`）按 uid 找，找到就走 `VideoFushiPage.neutralizedRemote(sourceReview: link, ...)` 流播复习；`video_fushi_page.dart` `_applyLoad` 的字节指纹判据对远端条目不再套用（远端字节在 host 上，本机无文件可比，原样会必报指纹不符）。host 不可达 / 清单里没有仍提示没有来源。
- **[x] ② 已加自动化测试** — `fushi/test/anki/card_source_remote_video_test.dart`（uid 匹配纯函数 + 书链接不匹配 + 接线守卫）。
- **备注**：未真机验证（无 host + 手机 + Anki 回跳环境）；只覆盖互联 host，Jellyfin / 云盘等其它远端源的条目 id 与 bookUid 不同键，不在本次范围。
