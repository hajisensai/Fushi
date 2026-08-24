## BUG-1804 · 游戏内 WebView 查词卡 PNG 全帧重采导致弹出与滚动卡顿
- **报告**：2026-08-24（用户运行时报告，已脱敏）
- **真实性**：✅ 真 bug。SGRE 的 1592×1020 游戏内查词卡每次弹出或滚动都经
  `GlobalLookupWindow::CaptureBgraAsync` 调用 WebView2 `CapturePreview(PNG)`，再做 WIC
  解码和共享内存整帧发布（`fushi/windows/runner/global_lookup_window.cpp`）。真实运行日志中
  连续重采的起始间隔为 180–246 ms，实际只有约 4–5 FPS；查词请求本身约 334–392 ms，
  不是这次滚动卡顿的主因。
- **[ ] ① 未修复** — JPEG 真机仅把连续重采中位间隔从约 190.5 ms 降到 161.3 ms，
  仍只有约 6 FPS，不能作为修复。主路改为把透明 WebView2 composition HWND 直接贴到
  游戏客户区，让浏览器合成器原生滚动；JPEG/PNG 只在找不到可用游戏 HWND 时回退。
  同时移除 `galFrameDirty` 和逐输入/逐帧的同步 flush 日志。嵌套 union 变化时，已显示的
  direct HWND 现在原位扩缩，不再先移到 `OffscreenX()`、等待两次 rAF 后再搬回。后续性能
  追踪又定位出两条共享热路径并完成代码修复：global-lookup host 把每个 static revision 的
  `data:font` 一次解码成同源 Blob URL，root/nested/reload 不再逐 iframe `eval` 约 12.2 MiB
  base64；`popup.js` 三镜像把 favorite/duplicate 状态探测移到词条接近可见时，并按同词条
  合并在途请求、换代时作废旧结果，避免关闭弹框后仍把整批 Anki 请求跑完。最新失败边界又
  收敛到 child `popup.html` browsing context：host 现保留一个有界的已加载子 realm，root
  就绪时预灌当前 static revision/字体，首次 child 只注入 entries/render；关闭后停泊并以新的
  单调逻辑 frame id 复用。补池在子卡首帧后启动，并用 50 ms watchdog 覆盖离屏 WebView rAF
  暂停；已挂载 shell 绝不重排（Chromium 重排祖先会重载 iframe）。停泊/销毁同时清除 host
  bridge route，并 drain frame-local pending Promise，避免跨代串框和闭包累积。最新 Windows
  Debug 构建已完成并在原 SGRE 会话启动；用户随后要求提交上游 PR，但定位、滚动、嵌套零
  整窗闪烁和延迟的最终显式通过回报尚未单独记录，因此本项保持未勾选。最新截图中 child
  先按旧 HWND 边界被裁掉、随后才补全，是另一条同生命周期竞态：旧 reveal gate 只确认
  child 左上角已落入窗口，未确认右/下边界与 HRGN 已提交。host/Dart/native 现以单调
  `geometryEpoch` 把 bbox、shellRects、`SetWindowPos` 和 reveal/captureReady 串成一次事务；
  只有原生成功提交同一 epoch 的完整四边后才揭示 child，旧 epoch/同尺寸 ABA 回执和恢复
  超时均不能把半成品上屏。几何门修正后的 7 个完整 nested 样本总时延均值仍为
  723.6 ms；其中 nested→overlaySize 均值 275.6 ms、native resize→captureReady 均值
  337.0 ms，而根卡后一区间中位仅 34.45 ms。对应源码证明同一事务被同步画了两次伴随
  阴影：`SetShellRectsFromCsv` 在旧 HWND 尺寸上抢跑一次，随后的 `SetWindowPos` 又经
  `WM_WINDOWPOSCHANGED` 画一次；每次还对大卡内部逐像素执行 `sqrt/exp`。现已让 shellRects
  只提交 HRGN/epoch，等待 matching resize 后以新尺寸画一次，并把栅格热循环缩到卡片外围
  阴影带；卡内 punch-out 改为每扫描线一次求 span 后连续清零，保持多卡圆角与透底语义。
  提交前的生命周期审计还复现了 `R,A,B → R,C` 会先销毁旧 A/B、再等待隐藏 C 的几何门，
  必然产生 root-only 闪帧；host 现以 route-scoped pending suffix swap 保留旧后缀，用 old+new
  union 完成几何事务后在同一 JS task 揭示新层并清理旧层，同时用 payload 逻辑深度设置
  `z-index`，避免 retiring 物理 realm 把后续孙层压到父层下面。
- **[x] ② 已加自动化测试** — Dart/源码契约测试钉住游戏视口坐标、direct surface 回执、
  composition 主路先于 CapturePreview 回退、direct 上屏后不再响应 dirty 整帧重采，以及
  已显示 direct HWND 的嵌套 resize 不再走屏外停车；Node 状态机另钉住首次 child 不新建/
  不重排 iframe、关闭再开仍复用同一 realm、逻辑 id 轮换、旧 bridge 清理、池上限、空栈释放
  以及 suspended-rAF watchdog。2026-08-24 定向 Node 与 6 个 lookup Dart 文件共 161 项通过。
  后续 geometry epoch 用例另覆盖 down-right/up-left 四边门、同 bbox 但 HRGN 变化、旧 epoch
  不得移动/揭示/完成 capture、beginLookup 单调性和 iframe 回收后的陈旧 rAF；最新定向
  Flutter 65 项、Node host/bridge/popup 用例及 lookup 静态分析均通过。
  伴随投影守卫另钉住 shellRects 阶段不得同步重画、WM_WINDOWPOSCHANGED 仍是正确尺寸的
  单漏斗，以及外围带栅格/扫描线 punch-out，避免性能修复退回整卡逐像素计算。host Node
  守卫另覆盖祖先替换期间旧后缀存活、old+new union、matching commit 同步交换、交换后收缩、
  逻辑层级 `z-index`，以及 append/truncate 不进入等待路径。
- **字体时延证据（不是范围锁死根因）**：实际启用的 Noto Sans JP 为 9,589,900 bytes，
  base64 静态脚本约 12.2 MiB。Dart 已按字体路径/mtime/size 缓存，不会每次查词都重新读盘
  或编码；稳定 root 也只在 static revision 未知时跨平台通道发送一次。但每个新 nested
  iframe 的 revision 初始为空，仍会重新 `eval` 整份静态脚本。运行日志中暖 root 到 direct
  surface 中位约 203.9 ms；新 nested 且 union 变化时中位约 902.2 ms，其中 nested accept 到
  geometry 中位约 321.3 ms。故字体可解释冷嵌套和其他模块首次新建子 WebView 的部分延迟，
  不能解释 BUG-1806 的固定红框，也没有证据表明稳定复用的其他模块 root 查词被本轮缓存
  改动拖慢。字体资源 URL / `document.fonts.ready` reveal 门应在同构开关字体 A/B 后另行落地，
  后续新构建 7 个完整 nested 样本进一步得到总时延中位 968.0 ms：host accept→geometry
  260.7 ms、geometry→captureReady 589.5 ms、captureReady→direct surface 3.9 ms；因此本轮
  只消除有直接代码证据的逐 iframe base64 重解析，不删除 `document.fonts.ready` 正确性门。
- **child realm 冷启动证据**：同一真机会话中 root 查词中位 169.1 ms，而 nested 中位
  686.8 ms；selected→nested 日志仅 67.9 ms，nested 接收后到首个 overlay 约 241.7 ms、
  首个 overlay 到 rendered 约 362 ms。旧 host 对每个新单调 child id 都执行
  `createElement('iframe')` 并导航 `popup.html`，关闭即移除；因此第一个可执行失败边界是
  iframe load/inject/layout，而不是 Hook 文本、注入字体文件读取或词典搜索分发。
- **后台洪泛证据**：同一会话记录到 258 条 `favoriteCheck` 和 255 条 `duplicateCheck`
  回复；后者通常约 300 ms/条串行，80-entry 查词关闭后仍可继续数秒，且每条回复都会同步
  flush 日志。可见懒加载/在途去重覆盖所有共用 `popup.js` 的查词模块，既缩短首屏同步 DOM/
  bridge 工作，也阻止不可见词条形成跨弹框后台积压。
- **备注**：继续使用原有 hook 文本、hook 音频和游戏内位图通道；不启用系统录音、
  loopback，也不退回独立浮窗。
