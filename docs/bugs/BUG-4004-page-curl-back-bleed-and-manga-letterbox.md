## BUG-4004 · page-curl-back-bleed-and-manga-letterbox
- **报告**：2026-11-03（用户：iPhone 录屏 + 截图，「卷页模式着色还有不少问题，还有穿透」「漫画穿帮严重，跟画面大小不一致」）
- **真实性**：✅ 真 bug。用户 2026-11-04 纠正方向：纸背**要**像苹果图书那样透出镜像正文，「穿透」不是指透字；毛病在着色和折痕。根因：
  1. 纸背几乎全是纸色：`fushi/shaders/page_curl.frag` 旧 `backAt` 只混入 7% 镜像正文（`page_curl.dart` 旧 `setFloat(12, 0.07)`），看着像一层脏纸，不像苹果图书那样能看出反写的正文。（第一轮误判成「不该透字」，改成了纯纸色背面，已推翻。）
  2. 折痕：圆柱两半明暗不连续（背面 0.8 对正面 0.78，平铺背面又单独压暗），第一轮还在翻起那片的纸边上描了一道 1.5px 暗线。纸边转过圆柱的那一段在屏幕上本来就是弯的，描线把这段弧描成一道带圆头的硬「折痕」（用户截图 6）。
  3. 漫画把整个视口当纸：`PageCurlController` 几何以视口为纸面，快照里的黑边也被当成纸卷起，背面画成纸色伸进上下黑边（截图 4/5）。
- **[x] ① 已修复**：
  - 纸背 = 镜像正文蒙一层纸色（`kPageCurlBackVeil` = 0.6，正文约四成浓度透出）。
  - 明暗只随圆柱表面朝向连续变化：平铺背面与圆柱顶同为 1；`rollShade(k) = mix(1, 0.84, k²)` 正反两半共用，轮廓处同值；圆柱背面中段加一道柔和高光。不画任何描线。
  - 投影降到 0.18。
  - 漫画：`PageCurlHost.paperRect()` 经 `window.__mangaCurlPaperRect(spread)` 量当前（往回翻时为预览中）跨页 `.manga-page` 的外接框，几何改在纸面局部空间计算，纸面外直接露出下面。
- **[x] ② 已加自动化测试**：
  - 单测：`fushi/test/reader/page_curl_controller_test.dart`（纸面矩形 4 例）+ `fushi/test/media/manga/manga_page_curl_paper_rect_test.dart`。
  - 真 app 像素探针 `fushi/integration_test/helpers/page_curl_probe.dart`：卷到一半停住抓 Flutter 图层，用与着色器同一套几何判两件事。① 平铺纸背不透明，且各通道随快照里镜像位置的同一通道线性变化（相关系数 ≥ 0.8，斜率 ≈ 1 − veil ± 0.15）。② 纸面外除翻起那片自身的投影外，不比卷页前更亮。
  - 探针接进 `page_curl_real_app_test.dart` / `manga_page_curl_itest.dart`。
- **备注**：iOS 上漫画 itest 改用本地导入卷（在线漫画源在 iOS 被商店合规拿掉，原夹具打不开阅读器），小说 itest 的 CDP 触摸段在 WKWebView 上跳过（无 CDP）。
