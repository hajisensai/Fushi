## BUG-2010 · 作品资料页一拉到前台就闪回加载态
- **报告**：2026-09-01（用户：「一直闪烁啊」+「现在的 fushi 一拉到前台就闪」，附两张「作品资料」页截图：AppBar 正常渲染，内容区整片空白、只剩正中一个极小的加载指示点）
- **真实性**：✅ 真 bug。根因是 `fushi/lib/src/pages/implementations/video_work_detail_page.dart:57` 把 `FutureBuilder.future` 写在 `build()` 里现取（`database.getMediaCollectionById(collectionId)`），`VideoWorkDetailPage` 当时还是 `StatelessWidget`。于是**每次重建都产生一个新 Future**，FutureBuilder 走 `didUpdateWidget` → `_snapshot.inState(ConnectionState.none)` → 该 builder 判的 `snapshot.connectionState != ConnectionState.done` 成立 → 整页落回 `Scaffold(body: Center(adaptiveIndicator))`；同时子页 `MediaCollectionDetailPage` 从树上消失、以**全新 State** 重建，它自己的 `_loading`（`media_collection_detail_page.dart:115`，全文件只有初值 `true` 与 `:358` 置 `false` 两个赋值点）一并复位 → 剧集列表整份重查。用户截到的正是这一帧。
  - **重建从哪来**：`fushi/lib/main.dart:780` 在 `AppLifecycleState.resumed` 调 `AppModel.refreshSystemPalette()`，而桌面端每次窗口激活都会走一遍 resumed；`theme_notifier.dart:462` 当时是**无条件** `notifyListeners()`（只要 `appThemeKey == 'system-theme'`，即动态取色主题），系统色一动没动也照发 → 主题变更 → 全树重建。两者叠加 = 「一拉到前台就闪」。
  - **同形状但不闪的两处**（一并修，但性质不同，勿混记）：`collection_detail_shared.dart:59`（标签 chip 行）与 `collection_relations_section.dart:267`（相关作品区）也把 future 写在 build 里，但它们的 builder 只读 `snap.data`，而上面那个 `inState(ConnectionState.none)` **保留 data**，所以旧结果继续渲染、并不闪。它们的代价是**每次重建都白查一次库**。这点经变异实测确认：最初按「也会闪」写的断言在变异下不红，判断已纠正。
- **[x] ① 已修复** — `969f2d43e7`：
  1. `VideoWorkDetailPage` 由 `StatelessWidget` 改为 `StatefulWidget`，合集行查询缓存在 State，身份只由 `(collectionId, database)` 决定，`didUpdateWidget` 里才重取；
  2. `collection_relations_section.dart` 把查询提进 State（`initState` / `didUpdateWidget` / 绑定成功后重取），顺带消除了只为翻 `key` 而存在的 `_refresh` 计数器——future 的身份变化本身就是「该重取」的信号；
  3. `collection_detail_shared.dart` 的标签查询改记忆化 getter，身份 = `(合集 id, detailTagsRefresh)`；
  4. `theme_notifier.dart` 的 `refreshSystemPalette` 加幂等判据：系统调色板/强调色没变就不广播（`CorePalette` 与 `Color` 都实现了 `operator ==`）。这是放大器修复——少一次无谓全树重建，任何同类页面都少一次被打回加载态的机会。
- **[x] ② 已加自动化测试** — 两个文件，**四处变异全部实测必红**：
  - `fushi/test/pages/detail_future_identity_test.dart`（3 条）：用 builder 式 `_RebuildHarness` 模拟「主题通知 → 全树重建」（**必须经 builder 现造 child**，直接复用同一个 child 实例会被 Flutter 的 `identical` 短路，测不到重建），钉 ①「重建后子页仍在树上且 State 原地复用、不退回加载态」②「重建后不许再对库发查询」——后者用 drift `QueryInterceptor` 数 `runSelect`，不按表名过滤（`pumpAndSettle` 后树已静止，此后任何 select 都只能来自重建）。
  - `fushi/test/models/theme_notifier_palette_idempotence_test.dart`（4 条）：mock `io.material.plugins/dynamic_color` channel，钉「首次取色广播 / 同色重复刷新不广播 / 真变了照常广播」。变异（删 `if (unchanged) return;`）实测 `Expected: <1> Actual: <4>`。
- **备注**：
  - **未做真机复测**。修复与测试都在 widget 层验证；「切走再切回 Fushi 主窗不再闪」这一条没有 Windows 真机证据，按纪律不得记为已验证。
  - 触发条件依赖主题设为**动态取色**（`appThemeKey == 'system-theme'`，也是默认值）。固定主题的用户走不到 `notifyListeners()`，本来就不该闪——如果有用户在固定主题下仍报闪，那是另一条重建源，不能并入本条。
  - `theme_system_accent_test.dart:84` 那条源码扫描守卫取 `refreshSystemPalette` 函数体查 `getCorePalette`/`getAccentColor`，本次改动未触碰这两处，已实测仍绿。
