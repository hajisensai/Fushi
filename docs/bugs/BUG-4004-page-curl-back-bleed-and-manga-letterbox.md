## BUG-4004 · page-curl-back-bleed-and-manga-letterbox
- **报告**：2026-11-03（用户：iPhone 录屏 + 截图，「卷页模式着色还有不少问题，还有穿透」「漫画穿帮严重，跟画面大小不一致」）
- **真实性**：✅ 真 bug，三处根因：
  1. 纸背透字：`fushi/shaders/page_curl.frag` 旧 `backAt` 把镜像正文按 `uBack.a`（`page_curl.dart` 旧 `setFloat(12, 0.07)`）混进纸背，黑字在纸背上留下可见的镜像字形（视频里「これはね…」、漫画里反写的 episode 标题）。
  2. 翻起的纸背与正面同色、外缘没有轮廓、投影只有 0.16 且极窄：竖排斜卷时纸背盖住的正文看起来像被「擦掉」（截图 1 红框）。
  3. 漫画把整个视口当纸：`PageCurlController` 几何以视口为纸面，快照里的黑边也被当成纸卷起，背面画成纸色伸进上下黑边（截图 4/5）。
- **[ ] ① 修复（未推送）** — 着色器重写：纸背不再采样正文，纸色 × `kPageCurlBackTone`(0.95) × 卷起处明暗，外缘 1.5px 轮廓线，翻起那片投到正面的阴影加深加宽；`PageCurlHost.paperRect()` 新增，漫画经 `window.__mangaCurlPaperRect(spread)` 量当前（往回翻时为预览中）跨页 `.manga-page` 外接框，控制器几何改在纸面局部空间（书脊 / 拎起的角在页图自己的边上），纸面外直接露出下面。
- **[ ] ② 自动化测试** — 单测 `fushi/test/reader/page_curl_controller_test.dart`（纸面矩形 4 例）+ `fushi/test/media/manga/manga_page_curl_paper_rect_test.dart`，31 绿；真 app 像素探针 `fushi/integration_test/helpers/page_curl_probe.dart` 已接进小说 / 漫画卷页 itest（纸背均匀度 ≤3、纸面外不变亮），**尚未跑完**（本机内存不足被回收）。
- **备注**：iOS 真机 / 模拟器未验。
