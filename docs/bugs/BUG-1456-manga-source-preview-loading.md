## BUG-1456 · 漫画源预览并发拉图、超时与重复操作
- **报告**：2026-08-03（用户：漫画源预览不要一次拉完图片；有数据时延长超时；预览和安装加载完成前不能重复点击）
- **真实性**：✅ 真 bug。预览网格里的每个封面组件都会直接调用 `fetchSourceImage`，没有页面级并发闸门（`hibiki/lib/src/media/manga/mihon/mihon_source_browse_page.dart:634`）；桌面封面代理把整个响应固定限为 45 秒，持续收数也会被切断（修复前 `hibiki/lib/src/media/manga/mihon/desktop_mihon_runtime.dart:173-191`）；扩展条目的预览与安装回调没有进行中状态（修复前 `hibiki/lib/src/media/manga/mihon/mihon_extensions_page.dart:571-581`）。
- **[x] ① 根因修复** — 浏览网格共享最多 4 并发的 `MihonSourceImageLoadQueue`；桌面封面改为 90 秒首响应和可由每个数据块续期的 90 秒空闲超时；同一扩展的预览/安装共享条目级互斥状态并显示进行中指示（实现提交 `21cd7d979`）。
- **[x] ② 已加自动化测试** — `hibiki/test/media/manga/mihon_source_browse_page_test.dart` 覆盖 4 并发上限；`mihon_source_image_timeout_test.dart` 覆盖超时延长、数据块续期和真实停滞超时；`mihon_extensions_page_test.dart` 覆盖预览/安装双击互斥与按钮禁用。
- **备注**：聚焦 3 文件测试共 11 项通过；6 个相关实现/测试文件 `flutter analyze --no-pub` 通过。按用户要求未等待完整编译或设备验收。
