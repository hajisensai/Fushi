## BUG-2230 · 网页流媒体页与作品详情页的加载态没有返回入口，且 init 异常无归宿
- **报告**：2026-09-07（BUG-2229 修完后的同族横向审计，三个子代理分域扫全仓）
- **真实性**：✅ 真 bug（2 个文件 3 处渲染分支 + 2 处异常无归宿）。

  与 BUG-2229 同一病根：仓库里绝大多数页面走 `FushiPageScaffold` / `FushiToolScaffold`，
  它们的 `_defaultLeading`（`fushi/lib/src/utils/components/fushi_material_components.dart:2288`
  与 `:2433`）在 `Navigator.canPop()` 时**无条件**插一颗返回箭头 —— 所以天然安全。
  出问题的全部集中在**绕过共享脚手架、自己拼裸 `Scaffold`** 的视频域页面：它们的退出入口
  挂在「就绪」分支上（播放器内顶栏 / `_buildAppBar`），而早退分支里那个顶栏根本没挂载。
  漫画页 `manga_fushi_page.dart:4161` 早就把规矩立对了：「出口不是内容的一部分，不随内容存亡」。

  1. `fushi/lib/src/pages/implementations/web_video_fushi_page.dart:1579` —— 未就绪早退分支
     `return const Scaffold(body: Center(child: CircularProgressIndicator()))`：无 AppBar、
     无 `CallbackShortcuts`（那些只挂在下面的就绪分支上）、无任何可见返回控件。
  2. 同文件 `initState` 的 `unawaited(_init())` **全程无 try/catch**，而 `_init` 里有几处
     真会抛的 await：`rootBundle.loadString`（资源缺失）、`WebViewEnvironment.create`
     （WebView2 Runtime 缺失 / 用户数据目录被占用，Windows 高发）、`_copyLoginCookiesFromBuiltin`。
     抛出后 `_failReason` 恒 null、`_row` 恒 null ⇒ **永久**停在上面那个无出口的转圈上。
     注意失败态分支（`:1571`）本身是带 AppBar 的 —— 只是异常根本走不到它。
  3. `fushi/lib/src/pages/implementations/video_work_detail_page.dart:202`（standalone 路径）
     与 `:69`（collection 路径的 `FutureBuilder`）两个加载分支无 AppBar，而它们各自的
     兄弟终态（`:208` / `:76`）都挂了 `appBar: AppBar()` —— 同一个 build 里口径不一致。
  4. 同文件 `unawaited(_load())` 同样无 try/catch，连着 6 次 DB 读，任一抛出（并发下
     sqlite 连接被毒化 / BUSY）⇒ `_loading` 永远为 true ⇒ 卡在无顶栏转圈上。
- **[x] ① 已修复** —
  - `web_video_fushi_page.dart`：新增 `_initGuarded()` 异常边界，未预期失败落进已有的带 AppBar
    失败态（`t.video_load_failed_generic`）；未就绪分支补 `appBar: AppBar()`。
  - `video_work_detail_page.dart`：新增 `_loadGuarded()` 异常边界，失败收敛到「未找到」终态；
    两处加载分支补 `appBar: AppBar()`。
  - 均不新增 i18n key，不改变正常路径行为。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_page_exit_affordance_test.dart`（2 条）
  - 行为守卫：用 override 过的 repository 让 `_load()` 第一跳就抛，断言页面收敛到「未找到」
    终态、有 `BackButton`、且点它真的退得出去。
    **注入点选择有实测依据**：先试过「关掉数据库」，实测那几个读并不抛而是落到 null，
    那样测出来的绿与 try/catch 有没有无关（恒真）；换成 `Future.error` 后变异才真的红。
  - 源码守卫：`video_work_detail_page.dart` 与 `web_video_fushi_page.dart` 里每一处
    `return Scaffold(` 都必须带 `appBar:`，带语料自检（扫到的处数下限），避免恒真。
    **刻意不扩到 `video_fushi_page.dart`** —— 那是另一种范式（BUG-102：退出并进 media_kit
    视频内顶栏，Scaffold 故意不挂 AppBar），拿同一把尺子量它会得到错误结论。
  - 变异实测：撤掉 appBar → 源码守卫红并精确报出 `web_video_fushi_page.dart:1600`；
    撤掉 `_loadGuarded` → 行为守卫红。恢复后 `FLUTTER TEST VERDICT: PASSED - 2 tests ran`。
- **备注**：同批审计判定为**疑似但不改**的（均有意设计或有 Esc 通路，改动收益低于风险）：
  `video_shader_dialog.dart:258` 下载进度框（注释明确「只有一条 pop 路径，避免误伤视频页路由」）、
  `dictionary_dialog_delete_page.dart` / `dictionary_dialog_import_page.dart`（controller 的
  finally 关闭，`dictionary_download_controller.dart:98` 注明是有意）、
  `anki_media_dedup_dialogs.dart:53`（进行中态，非终态）、
  小说阅读器 `reader_fushi_page.dart:3243` 首屏加载态（无可见控件但 Esc→`globalBack` 通路完好，
  且 `_startContentReadyTimeout` 有 8s watchdog 摘遮罩；口径与视频页加载态不一致，
  可作为后续 discoverability 补齐，非 P0）。
