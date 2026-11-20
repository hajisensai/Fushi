## BUG-4906 · 非 Windows 游戏页（串流接收端）宽屏仍是悬浮标题胶囊，与其它模块的页头大字顶栏不一致
- **报告**：2026-11-20（用户：「在宽屏的除了 Windows 的游戏现在还是悬浮胶囊。」）
- **真实性**：✅ 真 bug。widget test 挂真 `HomePage`（1400×900、`isWindows: false`）复现：书架 / 视频是重设计外壳的
  页头大字顶栏（大号页名 + 徽标 + 「书架 / 在线」一级切换 + 平铺动作），游戏页却是外壳叠的一枚「Game」**悬浮标题
  胶囊**（左上）+ 右上一枚悬浮动作胶囊，桌面下面还有一整行全宽「Stream / Texthooker」分段按钮；平板（Android /
  iPad，无台词视图）同样是标题胶囊 + 副标题行。根因：非 Windows 的游戏模块没有库页壳——
  - `fushi/lib/src/pages/implementations/game_stream_client_page.dart:83` 只是一个 `IndexedStack` 视图切换器，
    没挂 `FushiFloatingChromeOverlay(masthead: true)` / `FushiFloatingChromeBar` / 自己的动作槽；手机 / 平板连这层都没有，
    `home_page.dart:4359` 直接挂 `GameStreamLibraryPage`。
  - 页头于是由 `game_stream_library_page.dart:495` 的 `FushiPageHeader` 自己画，页面名靠外壳补：`home_page.dart:4753`
    （`homeShellBarTitleFor` 的 `gamesStreamClient` 例外）让外壳条照画页名、`home_page.dart:1925`（`_shellTitleInline`
    的同款例外）不把页名并进工具栏行——外壳条在 M3E 库页恒为收起形态，即那枚悬浮标题胶囊。三处例外都是为「串流
    形态是普通页头」打的补丁，与平台宽度判据无关，所以 macOS / Linux 桌面、Android 平板、iPad 宽屏全中。
- **[x] ① 已修复** — `GameStreamClientPage` 改成非 Windows 游戏模块的库页壳（两种形态都走它）：自持
  `FushiFloatingChromeController` + `FushiShellActionsSlot`，挂 `FushiShellTitleScope`（保留外壳页名、换成壳的动作槽）+
  `FushiFloatingChromeOverlay(masthead: true)` + `FushiFloatingChromeBar`，与书架 / 视频 / Windows 游戏库同构；一级切换改用
  库页共享的 `LibrarySectionTabs(floating: true)`（页头大字下画成「Stream / Texthooker」标题式切换），手机 / 平板
  （`offersTexthooker: false`）一级位放 `FushiFloatingChromeSoloTitle`。视图页头主位给零尺寸占位，串流库的刷新 / 设置动作
  登记进壳的槽、由工具栏动作组画；台词工作台按 `FushiFloatingChromeVisiblePadding` 让位。外壳侧删掉
  `homeShellBarTitleFor` 的 `gamesStreamClient` 参数与 `_shellTitleInline` 的游戏例外。没有新写平台判断（形态仍只看
  `GamesModuleForm` / `AppModel.gamesOffersExternalTexthooker`）。提交哈希：见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_games_stream_wide_chrome_test.dart`：挂真 `HomePage`，桌面
  （`isDesktop: true`）与平板（`isDesktop: false`）两种非 Windows 宽屏，断言游戏页子树里挂着 `FushiFloatingChromeBar`、
  外壳大标题条在游戏页画的页名与书架一致（都不画），并钉住台词切换只在桌面出现。修前两条都红（桌面：无浮动工具栏；
  平板：无库页壳），修后绿。`home_shell_bar_title_masthead_test.dart` 删掉钉旧例外的那条。
- **备注**：像素证据为 widget test 真实像素（`fushi/build/gssw_before/`、`fushi/build/gssw_after/`，不入库）。串流库独立
  挂载（无外壳）时仍画自己的「Game」页头与副标题；挂在壳里时副标题「在电脑上启动游戏并串流到这里」不再显示，与其它库页
  一致（空状态文案已说明配对）。Mac 真机：见 PR 正文。
