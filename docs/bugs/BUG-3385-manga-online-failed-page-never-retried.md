## BUG-3385 · 在线直读取页失败后该页永久白屏
- **报告**：2026-10-15（用户群反馈：漫画在线阅读不稳定，有时载入很慢）
- **真实性**：✅ 真 bug。取页失败时拦截器回 502（`fushi/lib/src/media/manga/reader/manga_fushi_page.dart:2588`），页图 `<img>` 只挂了 `load` 监听、没有 `error` 处理（原 `manga_overlay_html.dart` 图片几何循环）；整章在一个文档里懒加载、翻页不重建文档，浏览器不会再请求这张失败的图，退出重进才恢复。会话层（`online_manga_reader_session.dart`）其实允许失败页重取，只是没人再来要。
- **[x] ① 根因修复** — `manga_overlay_html.dart:1550` 图片 `error` 打 `data-load-failed` 标记并显示重试符号；`_retryPageImage`（`:1558`）换带 `retry` 参数的新 URL 重取（拦截器只看 path），触发点是读者动作：点失败页、翻到含失败页的跨页、长条模式失败页新进入视口，不盲重试。同批：会话层丢弃跳页后窗口外的排队预取、预取改「往前 4 / 往回 1」（对齐 chimahon / Mihon 只往后预取）、关章时经 `OnlineMangaPageCancellable` 取消在飞请求；Android 原生取图单独线程池（4），不再与页表 / 搜索共用 2 条线程。
- **[x] ② 自动化测试** — `fushi/test/media/manga/manga_reader_transforms_js_test.dart`「取页失败的页可以重取」（node 跑真生成脚本）；`fushi/test/media/manga/online_manga_reader_session_test.dart` 跳页丢旧预取 / close 取消在飞两条。
- **备注**：未真机复现用户原始「慢」路径。更大的提速项「Mihon OkHttp 连接池为 0（BUG-2272 有意为之）+ 每请求同步回问 Dart 代理策略」本次未动：恢复连接复用要同时做代理变更推送失效，并真机补测中途切换代理，另起 PR。
