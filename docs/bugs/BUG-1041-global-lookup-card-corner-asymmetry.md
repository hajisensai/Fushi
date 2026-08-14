## BUG-1041 · 查词浮窗卡片左侧圆角右侧直角
- **报告**：2026-07-22（用户，附截图：app 外查词浮窗（global-lookup 瞬态窗），白卡左上角圆角正常、右上角呈直角，右缘有一条全高暗色竖条）
- **真实性**：✅ 真 bug。2026-08-13 游戏内 BGRA 卡截图把首失败边界钉在 host 几何：
  `measureAndReport` 用 iframe 实测内容高度缩短 union bbox / native region，却没有把同一个高度写回
  shell。于是 CapturePreview 在 measured 下沿结束，而 `height:100%` 的 iframe 圆角仍位于 planned
  下沿，捕获会在底部圆弧前横切；WebView2 提升为独立合成面的 iframe 还可能越过父 shell 的
  `overflow:hidden`，共同造成右侧/底侧方口。PNG 解码、straight BGRA 与 KiriKiri `ltAlpha` 均能
  保留截图中已有的左上/子卡右上透明圆弧，不是根因。
- **[x] ① 已修复** — `global_lookup_host.js` 给每个 iframe 自身施加继承半径的 `clip-path`；
  `measureAndReport` 始终从 descriptor 的 planned height 重新计算
  `min(plannedHeight, measuredHeight)`，再把同一个 effective height 同步写回 shell，并用于
  shellRects、union bbox 与 host 命中。每张级联卡独立裁圆角，不给整张 union 位图套统一 mask，
  因而不会误裁重叠区或卡间内容。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/global_lookup_host_test.mjs` 已加入两类回归：
  measured height 缩短/回长/封顶时 shell 与上报 bbox 使用同一 effective height；iframe 自身必须继承
  圆角并施加 `clip-path: inset(0 round 10px)`。按用户要求本轮只落测试源码，未运行测试。
- **备注**：巡检跟进轮建档（原编号 1014→1034 均被 develop 占用[1014=Windows 安装器桌面图标守卫、1034=字幕列表行高裁剪]，合并 PR#366 时改为实时下一空号 1041）；与 BUG-1010 一起排 Windows 真机复现批次。
