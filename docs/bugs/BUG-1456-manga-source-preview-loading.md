## BUG-1456 · 漫画源预览并发拉图、超时与重复操作
- **报告**：2026-08-03（用户：漫画源预览不要一次拉完图片；有数据时延长超时；预览和安装加载完成前不能重复点击）
- **真实性**：✅ 真 bug。预览网格里的每个封面组件都会直接调用 `fetchSourceImage`，没有页面级并发闸门（`hibiki/lib/src/media/manga/mihon/mihon_source_browse_page.dart:634`）；桌面封面代理把整个响应固定限为 45 秒，持续收数也会被切断（修复前 `hibiki/lib/src/media/manga/mihon/desktop_mihon_runtime.dart:173-191`）；扩展条目的预览与安装回调没有进行中状态（修复前 `hibiki/lib/src/media/manga/mihon/mihon_extensions_page.dart:571-581`）。
- **[x] ① 根因修复** — 浏览网格共享最多 4 并发的 `MihonSourceImageLoadQueue`；桌面封面改为 90 秒首响应和可由每个数据块续期的 90 秒空闲超时；查询用 generation 丢弃旧响应，翻页按 URL 去重并在空页/纯重复页终止；同一扩展的预览/安装互斥状态下沉至 `MihonManager`，因此刷新、页面重建和离开重入都不能绕过，并且单一 preview marker 不再允许并发 session。
- **[x] ② 已加自动化测试** — `hibiki/test/media/manga/mihon_source_browse_page_test.dart` 覆盖 4 并发上限、旧查询响应隔离和重复页终止；`mihon_source_image_timeout_test.dart` 覆盖超时延长、数据块续期和真实停滞超时；`mihon_extensions_page_test.dart` 覆盖预览/安装双击互斥、按钮禁用与离开重入后的 manager 级占用。
- **备注**：6 个相关实现/测试文件及全仓 `flutter analyze --no-pub` 通过。聚焦测试在用例启动前被 `sqlite3` 构建钩子的 GitHub release-assets 下载超时阻断（errno 121），不记为通过；真实 Mihon 扩展与远端漫画源设备链路未验证。按用户要求未等待 CI。
