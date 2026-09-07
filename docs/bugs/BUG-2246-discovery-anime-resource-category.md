## BUG-2246 · 发现资源搜索把TMDB动画当普通剧集且不能手动切换类型
- **报告**：2026-09-07（用户：发现详情搜索「お兄ちゃんはおしまい!」没有匹配，并要求可手动设置类型）
- **真实性**：✅ 真 bug。Windows 2.2.4-debug.13790 在已打开的作品详情进入资源搜索可复现空列表；同日直接调用 Nyaa RSS，相同日文查询返回 43 条。`fushi/lib/src/media/video/discovery/video_discovery_adapters.dart:485` 原先只由 TMDB movie/tv 路径决定 discoveryCategory，丢失 genre_ids=16 的动画内容类型；`video_resource_registry.dart:46` 按此分类选择 provider，Nyaa 不参与普通 tv/movie。`video_discovery_acquisition_dialogs.dart:688` 原先始终返回 initialItem.reference，详情入口也没有类型选择器。
- **[x] ① 已修复** — 本文件同批提交：TMDB 根据动画 genre ID 保留动画分类，mediaKind 和 TMDB movie/tv ID 命名空间不变；资源搜索/订阅的共享 surface 提供动画、电影、剧集选择，立即按新类别重搜，下载/订阅提交携带同一引用。切换清除旧选择与订阅确认并递增请求代次，旧异步返回不再污染新类型结果。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/discovery/video_discovery_service_test.dart` 覆盖电影/剧集 × 列表/搜索 × 动画/非动画，走真实 TMDB adapter、详情 lookup、Nyaa provider 与 registry（HTTP fixture）；`fushi/test/pages/video_resource_category_test.dart` 覆盖手动切换、原身份保留、下载提交与旧请求慢返回；相邻资源 UI 的窄窗回归通过。
- **验证**：分类单文件 31 条通过；资源 UI / domain gate / wiring / alignment 五文件 26 条通过；5 个改动 Dart 文件定向 flutter analyze 无问题。PDFium 首轮下载阻塞在测试前，复用主 checkout 同版本缓存后实际运行通过；首次 dart analyze 的本机 perf 文件退出异常，后续 flutter analyze 成功。
- **备注**：未重建或替换用户正在运行的 Windows 安装；新版安装包原始用户路径和真下载入库 E2E 尚未执行。手动选择只更改资源内容分类，不把已有 TMDB tv ID 重新解释成 movie ID。未增加元数据刮削 provider，既有 AniDB 身份门控保留。
