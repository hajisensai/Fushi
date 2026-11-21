## BUG-5053 · Mihon 取图请求号拿 identityHashCode 拼，两个活页引用撞号时互相顶掉 / 取消错页
- **报告**：2026-11-20（路线图 #3722 c28 遗留）
- **真实性**：✅ 真 bug（代码路径坐实，概率低，无现场报告）。`fushi/lib/src/media/manga/library/online_manga_runtime_adapter.dart`
  的 `MihonLibraryAdapter._pageRequestId`（修前 :778）返回 `'download-${identityHashCode(page)}-${page.index}'`。
  `identityHashCode` 不唯一，同页号的两个活页引用（例如整章下载与在线直读同时取同一话，或两章的同页号）可能拿到同一个号：
  桌面运行时 `desktop_mihon_runtime.dart` `fetchImageRequest` 按请求号登记取图客户端，后到的请求会 `close()` 掉前一个
  的客户端（前一页直接失败）；`cancelChapterPages` 按号取消时也会取消到别人的页。
- **[x] ① 已修复** — 请求号改按页引用对象发单调递增序号（`Expando<String>`，随引用回收）：同一引用同一号（取消对得上），
  不同引用一定不同号。公开为 `@visibleForTesting MihonLibraryAdapter.mihonPageRequestId`。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/library/mihon_page_request_id_test.dart`：同一引用号不变；30 万个同页号
  活引用的号全不相同（旧实现按生日悖论几乎必撞）。
- **备注**：请求号前缀由 `download-` 改为 `page-`（在线直读也共用这条路径），原生侧不按前缀解析。
