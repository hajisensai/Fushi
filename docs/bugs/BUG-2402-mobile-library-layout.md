## BUG-2402 · 手机标签页头留白与筛选工具堆叠
- **报告**：2026-09-10（用户：手机顶部留白过大，书架工具和发现筛选占用内容空间）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_page.dart:1379` 已由 SafeArea 避让系统栏，`fushi/lib/src/utils/components/fushi_material_components.dart:1820` 又给手机自定义标签页头添加 page 顶距；书架 `tag_filter_bar.dart` 把排序、多选放在标签横滚列表末端；`video_discovery_page.dart` 在窄屏用 Wrap 常驻年份、国家、类型和排序，产生多行控件。
- **[x] ① 已实现** — 手机自定义标签页头移除额外顶距；搜索旁保留标签设置入口，排序/多选固定尾栏；同步保留实际进度但使用紧凑文字。手机发现页的高级筛选迁入可滚动底部面板，草稿应用后统一重新查询，取消不改现值。按真实视口宽度选择手机布局，避免界面缩放改变布局档位。
- **[x] ② 已加自动化测试** — `mobile_navigation_header_spacing_test.dart` 覆盖安全区/缩放/宽窗/显式 padding；`reader_library_toolbar_test.dart` 覆盖标签滚动、动作回调、命中区域、同步进度；`video_discovery_page_test.dart` 覆盖面板应用/取消/重置。
- **验证**：顶部及相邻页头测试 13 项通过；发现页 12 项通过；精确引用改动文件的邻接批共 611 项，610 项首轮通过，旧同步接线断言适配 compact 参数后该组 13 项通过（对账后无失败）。全量 `flutter analyze --no-pub` 无问题。Android 14 emulator-5554 真 app 焦点驱动用例通过：safeTop=49.45，header/tabs top=49.45；搜索/设置中心一致，排序/多选同排；Tab/Enter 可切至视频资源并打开筛选。证据位于 `.codex-test/mobile-layout-0910/`。未验证原 iOS 设备；Android 推荐内容截图仍处加载态，在线结果和卡片仅有 widget 数据回归。
- **关联窄屏问题**：发现页格子原固定宽高比 `.50` 把文字空间与封面宽度绑定，390px 长标题产生 24px 纵向溢出。现保留原列数，用 2:3 封面高度加实测两行标题、一行元数据和内边距计算格子高度；320/390px 带内容回归通过。
- **设计边界**：保留原底部导航、配色、数据来源和桌面工具布局；面板复用既有筛选键与查询契约，无新增持久化配置。
