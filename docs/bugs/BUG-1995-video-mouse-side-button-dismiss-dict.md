## BUG-1995 · 视频页鼠标侧键关词典无效（video scope 无鼠标通道）
- **报告**：2026-09-01（用户：关闭词典快捷键，小说鼠标侧键可以，视频不行）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/shortcuts/shortcut_action.dart`（`ShortcutScope.channels` 里 `video` 与 `home`/`global` 共用一个 case，返回 `{keyboard, gamepad}`——**mouse 通道被摘掉**）。

  直接后果是**设置页不给「添加鼠标按键」入口**（`binding_edit_dialog.part.dart` 的 `canAddMouse` 判 `channels.contains(mouse)`），用户根本绑不上这个键。reader 那边能用是另一条路：它正文是 WebView，侧键走 DOM `mousedown` → `callHandler('onPointerSeek')` → `resolveMouse(scope: reader)`（`reader_fushi/webview.part.dart`）。

  reader 之所以能用，是因为它正文是 WebView：侧键走 DOM `mousedown` → `callHandler('onPointerSeek')` → `resolveMouse(scope: reader)`（`reader_fushi/webview.part.dart:2435`）。视频页没有 WebView 正文，这条路复制不过来。全仓 `resolveMouse(` 原本只有 3 个消费点，无一个 scope 是 video。
- **[x] ① 已修复** — 把那条缺失的管线真的建出来，而不是在视频页复制一份 reader 的逻辑：
  - `video_fushi_page.dart` 新增 `_handleVideoPointerDown`，挂到**已有的**页面根 `Listener` 上（零新增层级）。`Listener` 不进手势 arena、不消费点击，media_kit 控件/进度条/字幕查词手势零变化。按钮号折叠复用 `domMouseButtonFromPointerButtons`——设置页的按键录制用的是同一个函数，两侧不共用就会出现「设置里录到侧键、运行时按另一个号解析」的错位。press-time 解析（不冻结绑定表），与键盘/手柄两条通道同构，执行体共用 `videoActionCallbacks`。
  - `shortcut_action.dart` 把 `video` 从 `home`/`global` 的 case 里拆出来，加上 `ShortcutChannel.mouse`，并改掉那段现在会变成假话的注释。
  - 新增 `ShortcutAction.videoDismissDict`（video scope，**默认空绑定**，与 `readerDismissDict` / `mangaDismissDict` 同形）。不加它的话用户只能把侧键绑到某个**真实**视频动作（「下一句」之类），浮层不可见时那个动作会照常执行——reader 干净正是因为有这个专用空绑定动作。它自动落进 `dictionaryPopupForwardedActions`（视频页转发整份 video scope），**弹窗表面同时生效，不需要第二套逻辑**。
  - i18n key `shortcut_action_video_dismiss_dict`，17 语言全部按 `reader_dismiss_dict` 的现成翻译回填（`--add` 只填 en/zh 会留 15 语言欠账）。
  - **registry schema v10 → v11 迁移**：video scope 的 mouse 通道**历史上开过**（与 reader/audiobook 共用 case 分支的连带产物），那期间绑上去的键从来没有生效过；管线建好后若不清理，这些被遗忘的绑定会**突然复活**并真的执行。v11 清掉 video scope 上的鼠标绑定（只清 video、只清鼠标通道——reader/audiobook 的鼠标绑定一直真实生效，绝不能碰）。它们从未生效过，清掉不改变任何用户**观察到**的行为；留着才是行为反转。
- **[x] ② 已加自动化测试** — `fushi/test/shortcuts/shortcut_registry_mouse_test.dart` 新增 3 条：video scope 开放鼠标通道且侧键可解析到 `videoDismissDict`（并断言未绑按钮仍无归属）；`videoDismissDict` 三通道默认全空；v11 迁移清掉 video 死绑定**且不误伤 reader**。
  - 566 tests ran, all passed（test/shortcuts 全域）。
  - 变异实测：把 `if (from < 11)` 改成 `if (false)` → 迁移用例正确变红；已还原。
  - 同时更新 `shortcut_action_wiring_guard_test.dart` 的执行体清单（登记 `video_fushi_page.dart`——鼠标是位置型输入，收在页面根 Listener 而非 `video_player_shortcuts.dart` 那份纯函数判决表里）与 `shortcut_channel_wiring_guard_test.dart` 里已过期的 `video/home/global.mouse` 注释（`knownUnconsumedChannels` 仍是空集，本次按「接上解析入口」销账）。
- **备注**：未做真机验证——本轮四个 bug 的验证都停在 `flutter test` 层。视频页鼠标侧键这条建议在 Windows 上手测一次（绑侧键到「关闭词典」→ 视频里查词 → 按侧键关浮层 → 浮层不可见时按侧键应无事发生）。`web_video_fushi_page.dart:380` 同样声明 video scope，改完自动跟随，未单独改。

- **复审补充（两条必须记的账）**：
  1. **v10 → v11 的「清掉老快照里 video scope 鼠标绑定」已撤销**。它的理由「通道关着的
     那段时间那些绑定从来没生效过」是错的：`dictionaryPopupInputSpecFor`
     （`dictionary_popup_input_bridge.dart`）读的是 `registry.bindingsFor(action)`，
     **完全不看 `scope.channels`**（`shortcut_registry.dart` 全文也没有任何按 channels
     做的装载期清洗），而视频页把整份 video scope 转发给词典浮层。所以老快照里那些绑定
     今天就在生效——指针压在浮层上按侧键，浮层 WebView 的 DOM mousedown 会回传并关掉
     浮层，恰恰就是本次报 bug 的用户最可能已经配好的那条。清掉 = 静默删用户正在用的
     配置。版本号仍留在 11（已发出去的快照写了 11 不能回退），只是不做迁移。
  2. **页级 `_handleVideoPointerDown` 里的浮层分支在正常路径上不可达**，功能只做到「半通」。
     词典浮层住在**根 Overlay**（`video_fushi_page.dart` 的 `_buildPopupOverlay`，跨路由
     生存），浮层可见时 `Positioned.fill(LookupDismissBarrier)` 铺满全屏，其内层
     `ColoredBox` 命中测试实心，`_RenderTheatre.hitTestChildren` 命中即 return，页面路由
     整棵跳过。同一文件里的 `_onDismissBarrierHover` 就是为「barrier 盖住后收不到 hover」
     而存在的铁证。**净效果**：指针压在词典浮窗上按侧键 → 通（走的是浮层输入桥那条老路，
     本 PR 只是打开了 video scope 的 mouse 通道让用户能绑）；指针落在浮窗之外（屏幕绝大
     部分面积）再按 → **原始症状仍然复现**。根治方向：`LookupDismissBarrier` 内部已有一个
     不入竞技场的 `Listener.onPointerDown`（滑关判轴用），把非主键那一路接到同一判据即可
     ——barrier 的语义本来就是「点它就关」。本轮未做，需真机验证后单独一条。
  3. `resolveMouse(button, scope: ShortcutScope.universal)` 那条回落是死分支
     （`ShortcutScope.universal.channels` 不开 mouse，设置页不给绑）；其注释里「Flutter 侧
     至今没有 PointerDownEvent → MouseBinding 派发管线」的理由已被本 PR 自己证伪。
- **本轮后续修复（承接复审第 2 条）**：
  - **页级 `_handleVideoPointerDown` 里的浮层分支已删除**。它在正常路径上不可达，留着
    只会让读代码的人以为「侧键关词典」由它承担。同时把该方法的文档改写成事实：
    本入口**只服务「浮层不可见」的表面**；浮层可见时指针事件被根 Overlay 的 barrier
    吃掉，关浮层由弹窗表面自己的回传路承担。
  - 新增 `fushi/test/shortcuts/video_pointer_channel_reachability_test.dart`（两条）：
    ① **widget 守卫**——用与真实结构同形的最小复刻（根 Overlay 两个 entry：页面层
    `Listener` + `Positioned.fill` 的 translucent/translucent/`ColoredBox` barrier）
    实测 `pageDowns=0 / barrierDowns=1`，把「barrier 吞指针」这个几何事实钉死；
    ② **源码守卫**——禁止 `_handleVideoPointerDown` 体内再出现 `_dismissTopVisiblePopup`
    / `_hasVisiblePopup`。
  - `shortcut_registry_mouse_test.dart` 补一条「channels 不含 mouse 的 scope，已有鼠标
    绑定仍可解析」（用 home scope），把复审第 1 条的判据——**channels 是设置页的录入门、
    不是派发门**——变成会红的断言，而不只是注释。
  - 变异实测：把关浮层分支加回入口 → 源码守卫红；barrier 叶子从 `ColoredBox` 换成
    非 opaque 的 `SizedBox` → widget 守卫红。均按唯一锚点还原。
  - **仍未修**：复审指出的「指针落在浮窗之外按侧键，原症状复现」这半边。根治方向按
    复审建议——`LookupDismissBarrier` 内部那个不入竞技场的 `Listener.onPointerDown`
    接上同一份绑定判据（barrier 的语义本就是「点它就关」）。需真机验证后单独一条。
