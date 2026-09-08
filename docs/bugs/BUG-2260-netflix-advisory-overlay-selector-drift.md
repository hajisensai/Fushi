## BUG-2260 · Netflix 分级提示 overlay 改用 .watch-video--advisories-container，三处隐藏选择器全部静默失效；内置播放器换集重载后 chrome 隐藏丢失

- **报告**：2026-09-08（用户：截图为 Netflix 播放画面左上角 "RATED 13+ / 暴力, 自杀"，
  「在 Netflix 视频内进行跳转制卡时，会出现此提示 can't you hide it with some js or css」）
- **真实性**：✅ 真 bug，两个根因。
  1. **选择器漂移（扩展 + 内置播放器都中）**。2026-09-08 用保留登录态的 pywebview/WebView2
     探针（`nf_dom_probe.py`，每 300 ms 扫 `[class*=evidence|maturity|rating|advisor]` +
     `RATED` 文本节点）实测 `/watch/81236554`，提示出现时的 DOM 是：
     ```
     div.watch-video--advisories-container
       div.advisory-container            （隐藏态加 .advisory-hidden，节点常驻不摘）
         div.advisory-background.advisory-transition-enter-done
         div.advisory.advisory-transition-appear-done
           div.advisory-bar
           div.advisory-content[data-uia="advisory-content"]
             h4.advisory-header[data-uia="advisory-header"]   "RATED 7+"
     ```
     仓库里三处隐藏用的选择器——扩展常驻清单 `fushiNetflixNextEpisodeSelectors()`
     （`tools/browser-extension/content.js:1329`，`.watch-video--evidence-overlay-container` +
     三条 `*maturity*`）、扩展录制期 `hideStyle`（`content.js:876`）、内置播放器
     `HIDE_CHROME_CSS`（`fushi/assets/web_video/web_video_glue.js:134`）——全文没有一个
     `evidence` / `maturity` 节点可命中，三处**同时静默失效**（BUG-2170 备注里预言过的
     「站点换类名整条静默失效」正是这次）。BUG-2170 的时间门只管**开播窗**，逐句 seek
     后重弹的提示不在它的覆盖面里。
  2. **内置播放器换集后隐藏态丢失**。`_runMineQueue`（`web_video_fushi_page.dart:903`）只在
     队列开跑前调一次 `_setPlayerChromeHidden(true)`；队列行属于别的集时 `_navigateForMining`
     走 `web.loadUrl` **整页重载**，上一份文档里的 `<style id=fushi-web-video-hide-chrome>` 随
     文档一起没了，而 `onLoadStop`（`:1831`）只重挂了字幕隐藏、没重挂 chrome 隐藏——此后
     每张卡都带控制条 + 分级提示。隐藏态的拥有者是 Dart，却没在新文档里重新落地。
- **[x] ① 已修复** —
  - `fushi/assets/web_video/web_video_glue.js`：集中定义 `NETFLIX_ADVISORY_SELECTORS`
    （advisories 容器 + `[class*="watch-video--advisories"]` 哈希兜底 + 旧 evidence 选择器作
    回滚兜底）；Netflix 页 document-start 常驻注入 `#fushi-web-video-hide-advisory`
    （`display:none`，glue 每份文档重新跑，整页换集不丢）；`HIDE_CHROME_CSS` 拼入同一组。
  - `web_video_fushi_page.dart`：`onLoadStop` 按 `_mineRunning` 重挂 chrome 隐藏（与字幕隐藏
    同款）；`_navigateForMining` 画面就绪后开录前再挂一次（页面侧按 style id 幂等）。
  - `tools/browser-extension/content.js`（+ `fushi/assets/browser_extension/` 镜像，
    `dart run tool/sync_browser_extension.dart` 同步）：常驻清单与录制期 `hideStyle` 都补
    advisories 两条；版本横幅 v47 → v48。
- **[x] ② 已加自动化测试** — `fushi/test/mining/netflix_bug2260_advisory_overlay_guard_test.dart`
  （源码扫描，扩展两镜像 × 2 + glue × 2 + Dart 页 × 2）：常驻清单 / 录制作用域 / glue 常驻
  display:none / chrome 清单复用同一常量 / onLoadStop 重挂 / 换集就绪重挂。版本守卫
  `netflix_bug685_seek_gate_guard_test.dart` / `netflix_mining_robustness_guard_test.dart` 随
  v48 更新。
- **备注**：
  - 探针里视频未真正推进（软件 DRM 档下 `currentTime` 停在续播点 1037 s），所以「seek 后是否
    重弹」本次未量到；用户报告的就是 seek 制卡时出现，按常驻隐藏处理不依赖这一点。
  - 旧的 `.watch-video--evidence-overlay-container` / `*maturity*` 选择器**保留**：Netflix 分区域
    灰度或回滚时仍有用，且删掉会牵动 BUG-702 / BUG-2170 守卫，不值得。
  - 下次再漂移的判别办法就是本次探针：用 `%APPDATA%\pywebview` 登录态 profile 开 watch 页，
    扫 `RATED` 文本节点的祖先链，别再猜类名。
