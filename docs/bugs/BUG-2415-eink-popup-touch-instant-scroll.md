## BUG-2415 · 墨水屏瞬时滚动只接了滚轮，触摸拖动仍走原生惯性滚动
- **报告**：2026-09-10（用户：墨水屏的查词弹窗上下瞬时滑动还没做吗）
- **真实性**：✅ 真 bug —— 根因 `fushi/assets/popup/popup.js:5818`（BUG-2284 把
  `window.__fushiPopupInstantScroll` 只接进了 `__fushiPopupWheelListener`，全文件没有第二个
  消费点）。设置项 `lookup.popup_instant_scroll` 的文案写的是「Jump the lookup popup by fixed
  distances without animated scrolling **for e-ink screens**」（`strings.i18n.json:2710`），
  没有任何「仅限滚轮」的限定；可墨水屏设备是 Android e-ink 阅读器，**根本没有滚轮**，用户是用
  手指上下滑弹窗的。那条路径此前 100% 走 WebView 原生滚动：逐帧连续位移 + 松手后的惯性 fling，
  正是文案承诺要消掉的「animated scrolling」。于是在唯一真正的墨水屏输入方式上，这个开关等于
  没接线——与 BUG-2284 ① 认定的「三元两个分支等价 = 空开关」同一类，只是换了输入设备。
  弹窗的其余 eink 动效此前都已归零（入场淡入 `dictionary_popup_layer.dart:500`、侧滑关闭补间
  同文件 `:1348`、顶栏 swipe `swipe_dismiss_wrapper.dart:79`、CSS 通配 `popup.css:1987` 关掉
  全部 transition/animation），唯独触摸滚动这条漏网。
- **[x] ① 已修复** —— `popup.js` 新增触摸半边（三镜像逐字节同步：`assets/popup/`、
  `assets/browser_extension/vendor/`、`tools/browser-extension/vendor/`）。与滚轮同源但不同形：
  滚轮是离散 notch，可以「一格跳半屏」；手指是连续位移，同样按固定距离跳，但量化的是**手指行程**
  ——每滑够一步（视口 × `POPUP_EINK_TOUCH_VIEWPORT_FRACTION` 0.25，夹在 `[MIN_STEP 24, 一屏]`）
  就 `scrollBy` 一步、锚点同步推进一步，即「量化的 1:1 跟手」。保留方向反馈（与
  `_BodySwipeDismissDetector` 跟手期刻意保留 `Transform.translate` 同理，见 BUG-2283 备注），
  同时把整段滑动的重绘从每帧一次压成每步一次，`preventDefault` 再把松手惯性彻底掐掉——墨水屏上
  「松手后还要糊几秒」正是惯性拖出来的。偏好仍读 BUG-2284 已铺好的同一个
  `window.__fushiPopupInstantScroll`，不新增下发通道。
  - **接管判定放在 `touchstart` 一次定死，`touchmove` 里不再判轴**：Chromium 只在某帧 touchmove
    未被 `preventDefault` 时才启动原生滚动，一旦启动，后续帧 `cancelable` 变 false、再
    `preventDefault` 也没用。若留一段「判轴死区」不拦截，Android ~8dp 的 touch slop 恰好落在死区
    里，原生滚动会抢先起步 → 变成原生滚动与瞬跳**同时**位移（双倍）。所以要么从第一帧就拿下整轮
    手势，要么整轮不碰。
  - 整轮不碰的三条豁免（都在 `touchstart` 判）：多指（缩放/系统手势）、已有选区（选区手柄拖动也是
    touchmove，拦了就拖不动手柄，嵌套查词要靠它选词）、手指落在**真正横向溢出**的祖先上
    （`.expression-scroll` / `.gloss-image-scroll` / `.gloss-sc-table-container`）——判据是
    `scrollWidth > clientWidth` 的实际溢出 + `overflowX` 为 auto/scroll，不是只看 CSS 声明，
    所以短词头那种没溢出的 `.expression-scroll` 不会误触发豁免。
  - 只在 in-app 弹窗挂载：扩展镜像里 popup.js 与宿主页共用 document，非 passive 的 touchmove 会
    掐掉宿主页整页的合成器快速滚动路径（wheel 那条为此专门只挂 shadow host，见 BUG-1078），而
    墨水屏场景是 app 内弹窗。三镜像仍逐字节一致，差别只在运行期分支。
- **[x] ② 已加自动化测试** —— `fushi/test/dictionary/popup_touch_instant_scroll_guard_test.dart`
  共 23 条（7 条 × 3 镜像 + 2 条跨镜像）。单测里没有真 WebView，滚动本身无法直接断言（与既有
  `popup_instant_scroll_guard_test.dart` 同处境），所以钉死的是「开关 → 触摸行为」这条线上每一段
  **载荷位**的存在性：偏好真被触摸入口消费、touchmove 是 `passive:false` 且真的 `preventDefault`
  （少任一条则惯性照旧且**无任何报错**）、步长来自视口比例而非 travel 的函数、锚点按步长推进
  （少了它一次 touchmove 就跳到底）、补步循环有防御性上限、三条豁免都在 touchstart 判、横向判据
  看实际溢出、扩展分支不得挂 document 级触摸监听、三镜像的触摸块逐字节一致。
  判别力验证：把 `{ passive: false }` 临时改成 `true`，passive 守卫 + 三镜像一致性 2 条立刻红
  （退出码 1）；恢复后 23/23 绿。相邻既有守卫（`popup_instant_scroll_guard` /
  `browser_extension_popup_parity_guard` / `popup_css_eink_guard` /
  `browser_extension_popup_wheel_surface_guard` / `popup_wheel_native_residual_guard`）40/40 绿。
- **备注**：
  - **真机未验**：本机没有 Android 墨水屏设备，「手指滑动不再有惯性、按步跳」这条只在源码与守卫层
    验过，属 `implemented_unverified`。要落实需在真机开「查词 › 瞬时滚动」后滑弹窗对比。
  - 盘点时另发现三条**本次未修**的相邻缺口，都不在「触摸滑动」这条路径上，留作独立条目：
    ① `popupInstantScroll` 与 `einkMode` 完全解耦（`preferences_repository.dart:721-726` 有明确
    注释说这是刻意的 opt-in），所以开了墨水屏主题**不会**自动获得瞬时滚动，得再手动开一个开关；
    是否让 eink 隐含开启是产品决定，不在本 bug 内改。
    ② 滚动条 thumb 的「滚动时浮现 / 900ms 后消失」（`popup.js:6041` + `popup.css:234`）在
    `html.eink` 下无覆盖，等于每次滚完额外一次延迟局部刷新，且 thumb 是半透明灰。
    ③ 扩展侧从来没人挂 `eink` class（只有 `popup_settings_injection.dart:112` 一处），
    `vendor/content.css` 里整块 eink 覆盖是死码。
