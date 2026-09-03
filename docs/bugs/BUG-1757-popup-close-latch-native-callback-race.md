## BUG-1757 · 安卓独立查词窗连续查词后卡死关不掉——原生关闭回调被销毁中的旧 Activity 清掉，Dart 闭锁随即锁死
- **报告**：2026-08-20（用户：「手机上下滚动查词弹窗的时候查词，容易卡住，就是基本上滚动不了」；追问后澄清：「卡住以后，滑动查词弹窗只能动一点点，而且基本上不可使用」「可能关不掉弹窗？卡住的时候弹窗没变化感觉」）
- **真实性**：✅ 真 bug。根因**两侧各一半**：
  - 原生侧竞态 `fushi/android/app/src/main/java/app/fushi/reader/PopupEngineHolder.kt:62`（旧 `onFinish` 裸字段）+ `PopupDictFlutterActivity.kt:121`（onDestroy 无条件 `setOnFinish(null)`）；
  - Dart 侧闭锁 `fushi/lib/src/pages/implementations/popup_dictionary_page.dart:193-201`（`_close()` 先上锁、后办事、办砸不解锁）。
- **[x] ① 根因修复** — 原生侧关闭回调带 owner、注销时比对（消除竞态本身，并从 API 上删掉「无条件清空」入口）；`finishPopup` 把「有没有人真的接下这次关闭」回给 Dart，没接就解开 `_isClosing`（安全网）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_close_latch_test.dart`（8 例：`finishPopup` 四种返回语义的行为测试 + Dart/Kotlin 两侧源码守卫）。**变异实测**：分别去掉 Kotlin 的 owner 比对、去掉 Dart 的解锁分支，各自打红对应守卫；两次还原后源文件 sha256 与变异前逐字节一致（`4d2da6f5c8a5ecc07867d172a5f3174cd694271e40c63eb5aba3484df5562033` / `7c7f5fe40b72b309d1e37a8e791cbd47da7ac32df7e08cd7b097e83ae07702fc`）。

### 根因

触发路径就是用户原话里的「查词弹窗的时候查词」——**关掉一个查词窗、紧接着查下一个词**：

1. `PopupEngineHolder` 是 **object 单例**，关闭回调 `onFinish` 是它的字段（`:62`）；
2. 每个 `PopupDictFlutterActivity` 在 `onCreate` 里把它指向**自己**的 `finish()`（`:91`）；
3. 旧实现的 `onDestroy` **无条件**清空（`:121`），不检查当前回调是不是自己注册的；
4. Android 的标准生命周期顺序是「**新实例 onCreate/onResume → 旧实例 onStop → 旧实例 onDestroy**」，于是旧窗销毁时把**新窗刚注册的**回调清成 null；
5. 新窗随后调 `finishPopup` → `onFinish?.invoke()` 撞上 null，**静默什么都不做**，窗口留在屏幕上；
6. 而 Dart 侧 `_close()` 是**先上锁后办事**：`_isClosing = true` 已经置下，`finishPopup()` 的失败被完全吞掉（`popup_channel.dart` try/catch），也没有任何返回值可判。

`_isClosing` 全文只有三处（声明 / `didUpdateWidget` 复位 / `_close()` 早退+置真），**唯一的复位条件是「宿主推来一个新词」**。用户此刻想做的恰恰是关掉当前这个窗、而不是查新词，所以闭锁永远解不开：

- X 按钮、点卡外、横滑关闭、系统返回**全部**汇到 `_close()`，全部撞上开头那句 `if (_isClosing) return;` 静默早退 ⇒ 用户侧「**关不掉**」；
- 弹窗是活的原生 WebView（平台视图），不受 Flutter 侧任何状态影响，内容仍能滚 ⇒ 用户侧「**只能动一点点**」；横滑走 `_BodySwipeDismissDetector`，未过阈弹回、过阈滑出后调 `onDismiss` → 又被 `_close()` 早退，所以「滑走了窗口还在」；
- 整个过程没有任何重绘/布局变化 ⇒ 用户侧「**弹窗没变化感觉**」。

竞态依赖 Activity 销毁与新建的相对时序，所以是「**容易**卡住」而不是必现。

TODO-1336 曾经处理过同一个闭锁的**另一半**（warm 复用下 State 不随关闭销毁 → 首次关闭后闭锁永不复位），修法是在 `didUpdateWidget` 里复位。那条修复是对的，但它只覆盖「之后又查了新词」的情形；本 bug 是「关闭根本没发生、用户也没有再查新词」，`didUpdateWidget` 不会被触发。

### 修复

**原生侧（消除竞态本身）**：`onFinish` 与注册者合成一个 `FinishHandler(owner, callback)` 字段（两个 `@Volatile` 字段无法原子更新，读到「新 owner + 旧 callback」同样会关错窗）。`setOnFinish(owner, callback)` 注册，`clearOnFinish(owner)` **仅当当前回调确实属于 owner 时**才清。**不再保留任何「无条件清空」入口**——那个入口存在多久，这个竞态就存在多久。

**Dart 侧（安全网）**：`finishPopup()` 返回「有没有人真的接下这次关闭」（`result.success(handler != null)`），`_close()` 在 `!accepted` 时复位 `_isClosing`。通道异常、返回 null（旧协议）一律按 false 处理——宁可让用户能再点一次，也绝不把弹窗锁死。这样即使将来因为别的原因关闭没发生，也不会再退化成「关不掉」。

### 本轮实测排除的候选（别再重走）

调查中有三条链条自洽、但被实测否定，记下来避免重复劳动：

1. **「barrier 的横拖识别器霸占手势竞技场堵死 platform view」——不成立。** 用真的 `PlatformViewSurface` 做对照实验：盖一个**完全不带手势**的透明 `ColoredBox`，下层就已经收到 0 个指针事件；去掉 `ColoredBox`、只留 tap 手势则收到全部 14 个。真正挡住下层的是 barrier 的**透明填充盒**（对 hit test 实心），识别器无关。推论：「弹窗开着时正文收不到触摸」是 dismiss barrier 的**既有设计**，不是 bug。
2. **「弹窗自身 WebView 的 `LongPressGestureRecognizer(250ms)` 抢走纵向滚动」——不成立。** 同款识别器配置下，按下即滑、按住 300ms 再滑，平台视图都收到全部 14 个事件。
3. **「滚动中误触发查词打断滚动」——不成立。** `popup.js` 的点词路径有 mousedown/click 配对的 5px 位移阈值保护，滑动后抬手不会被判成点词。

另外复核过但未发现问题的：各宿主传给 `parkedPopupLayer` 的 `screen` 几何（BUG-692/135 家族）、`kPopupTopPullReleaseJs`（全 passive 只读）、BUG-1723 的 predictive-back 计数修复（守卫 7 条全绿，且 `canPop:false` 路径 detector 明确不接管、不动计数）。

### 附带落地（非本 bug 的修复）

同一分支上另有一次结构收口：四个表面各自手拼的 dismiss barrier 收成单一原语 `LookupDismissBarrier`（commit `e26cf98c03`）。它源于上面第 1 条那个**被否定**的假设，行为等价、既有测试全绿，但**不修复本 bug**，commit message 已写明。

- **备注**：真机未复测（用户此前叫停真机验证流程），证据为「原生生命周期顺序 + 单例字段归属」的代码级推导 + Dart 侧行为测试 + 两侧源码守卫 + 变异实测。用户侧的验证口径是：关掉一个查词窗后立刻查下一个词，新窗应当能正常关闭。
