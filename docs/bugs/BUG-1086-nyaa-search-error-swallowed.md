## BUG-1086 · Nyaa 搜索网络错误被吞成统一文案，真实报错不可见（生肉分类超时无从定位）
- **报告**：2026-07-25（用户：下载页发现 tab 搜「Watashi wo Tabetai, Hitodenashi」，「全部」能搜、切「生肉」分类转 20s 后只给「搜索失败或超时，请点重试」；要求把真实报错写出来）
- **真实性**：✅ 真 bug。根因两层：
  - `hibiki/lib/src/media/torrent/nyaa_client.dart:252`（旧版 `search()`）把**所有**异常和非 200 吞成空列表——真实网络故障（本机直连 nyaa.si 被墙，curl 复现 SSL 握手失败 exit 35；走代理四个分类全部秒回）要么被误报成「无结果」，要么只有 20s 超时后的统一文案。「生肉超时、全部能搜」只是直连被墙链路的间歇性，不是分类差异。
  - `hibiki/lib/src/pages/implementations/anime_download_dialog.dart` 错误态 `_buildErrorRetry` 只渲染统一 i18n 文案，异常对象在 `catch (_)` 里被丢弃。
- **[x] ① 已修复** — `NyaaClient.search` 改为抛错穿透（非 200 抛 `ClientException('HTTP <code>')`，底层网络异常原样上抛）；对话框 `_fetchTorrents`/`_searchAnime` 捕获后把 `error.toString()` 存入 `_torrentsErrorDetail`/`_animeSearchErrorDetail`，错误态展示真实异常串 + 「站点无法直连时可在下载设置配置网络代理」提示 + 「去设置」直达；订阅服务 `_check` 原有整体 try/catch 顺带修正「网络错误被当成无新集并清空 lastError」的隐性问题。
- **[x] ② 已加自动化测试** — `hibiki/test/torrent/nyaa_client_test.dart`（非 200 → 抛 ClientException 含状态码；底层握手异常原样穿透，不吞成空列表）；`hibiki/test/pages/anime_download_dialog_discovery_ux_test.dart`（错误态渲染真实异常串 + 代理提示 + 去设置按钮）。
- **备注**：超时本身是环境问题（直连被墙 + 系统代理「已配置但未启用」，app 下载客户端 auto 模式按 环境变量 > 已启用系统代理 > 直连 回退到直连）；app 侧根治就是把错误穿透出来引导用户配代理——下载设置本就有 auto/直连/自定义代理三档。
