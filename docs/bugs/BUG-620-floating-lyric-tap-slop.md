## BUG-620 · 悬浮字幕点击文字没反应的更深根因：tap/drag 阈值低于平台 touch slop
- **报告**：2026-07-08（用户：TODO-1268 复诉「点击文字还是没反应」，BUG-598 修完 BAL 后仍无反应）
- **真实性**：✅ 真 bug（根因 `hibiki/android/app/src/main/java/app/hibiki/reader/BaseFloatingService.java:255` 原 `Math.abs(dy) > 10`——拖动判别阈值硬编码 `10` **物理像素**，远低于平台 tap/drag 边界 `ViewConfiguration.getScaledTouchSlop()`（约 8dp ≈ 20-28px），普通点击手指滚动几 dp 就被判成拖动，`ACTION_UP` 走 drag 分支，`onOverlayTapped`/`handleTap` 从不触发 → 点词没反应）
- **[x] ① 已修复** — `BaseFloatingService.java` 拖动阈值改用平台 `ViewConfiguration.getScaledTouchSlop()`：`onCreate` 解析一次存 `touchSlopPx`（`dragSlopPx()` helper 带 `<0` 懒解析兜底，任何触摸都拿到正值，绝不会看到哨兵 -1 使「一切皆拖动」），`ACTION_MOVE` 用 `> slop` 替换裸 `> 10`。同时覆盖复用同基类的 `FloatingDictService`。分支 `todo1268-floating-lyric-click`，commit 见提交。
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/floating_overlay_tap_slop_guard_test.dart`（源码扫描守卫：阈值来源必须是 `getScaledTouchSlop()`、`ACTION_MOVE` 判别比较解析出的 slop、绝不再出现 sub-slop 魔法数 `> 10`、`onCreate` 解析 + helper 对 -1 懒解析兜底）。原生触摸无法在 host 跑、无法离屏复现悬浮窗时序，故用源码守卫钉阈值来源防回归，真机验收另行。
- **备注**：Android 悬浮窗「点击命中→拖动/点击判别」时序无法离屏复现，需真机验收（见「待验」）。与 BUG-598（BAL 后台启动 opt-in）是同一入口的**两层**根因：BUG-598 修「点击已送达 handleTap 之后的启动被拦」，本条修「点击在到达 handleTap 之前就被误判成拖动吞掉」——BUG-598 假设点击已送达，本条补上其缺口。

### 现象
Android 听有声书、显示悬浮字幕条时，点字幕里的日文词**没有任何反应**，不弹查词窗。控制按钮（⏮▶⏭🔒✕）却正常。用户在 BUG-598（把点词启动抽成后台启动 opt-in helper `startLookupActivity`）之后复诉「还是没反应」。

### 为何 BUG-598 没根治
BUG-598 只修了 `FloatingLyricService.handleTap` **收尾的启动**（`startActivity` → `startLookupActivity` 的 background-activity-launch opt-in），它隐含假设：点击已经送达 `handleTap`。但在**高密度手机**上，点击往往**根本没送到** `handleTap`。

关键对照——同一条悬浮窗里，**控制按钮点得动、点字幕文字不动**：
- 控制按钮（`FloatingLyricService.addButton` 里 `btn.setOnClickListener`）走各自的 `OnClickListener`，**不经过** `BaseFloatingService` 的 tap/drag 判别；
- 字幕文字的点词是**唯一**依赖 `BaseFloatingService.setupDragListener` 里「是拖动还是点击」判别再调 `onOverlayTapped` → `handleTap` 的路径。

所以「按钮正常、点字不灵」把根因精确锁死在这条 tap/drag 判别上（BUG-598 修的 BAL 与它并列，都在这条「仅字幕文字」路径里；BUG-598 修了后半段，前半段仍漏）。

### 根因（`BaseFloatingService.setupDragListener` 的 sub-slop 阈值）
```java
case MotionEvent.ACTION_MOVE: {
    float dx = event.getRawX() - initialTouchX;
    float dy = event.getRawY() - initialTouchY;
    boolean moved = getDragMode() == DragMode.FREE
            ? (Math.abs(dx) > 10 || Math.abs(dy) > 10)
            : (Math.abs(dy) > 10);          // ← 10 物理像素
    if (moved) isDragging = true;
    ...
}
case MotionEvent.ACTION_UP:
    if (isDragging) { ...savePosition... }
    else { onOverlayTapped(event); }        // ← 只有「非拖动」才点词
```
`10` 是**物理像素**（比较对象 `event.getRawX()` 是 px）。而 Android 官方的 tap/drag 分界是 `ViewConfiguration.getScaledTouchSlop()` = **8dp**；在 3.0x 密度手机上 8dp = 24px，在 2.75x 上 ≈ 22px。`10px` 只有平台 slop 的 ~40%。

后果：一个平台**判为「点击」**（移动量在 8dp slop 内）的普通手指点击，只要竖直方向滚动超过 10px（约 3.3dp）就被这里**判成「拖动」**——`isDragging=true`，`ACTION_UP` 走 drag 分支（`savePosition`，但位置几乎没变，无可见效果），**永不调** `onOverlayTapped` → `handleTap` 永不执行 → 查词永不启动 → 点词「没反应」。手指精确落点很难做到竖直零滚动，故表现为高密度机上点字几乎点不动。

`FloatingLyricService` 用 `DragMode.VERTICAL_ONLY`，只看 `dy`；`FloatingDictService`（FREE）同时看 `dx`/`dy`，同样受这条 sub-slop 阈值影响。

### 修复
把拖动阈值从硬编码 `10px` 换成平台 tap/drag 边界 `ViewConfiguration.getScaledTouchSlop()`：
1. `onCreate` 解析一次 `touchSlopPx = ViewConfiguration.get(this).getScaledTouchSlop();`（在 `setupOverlay` 挂 touch listener 之前）。
2. `ACTION_MOVE` 用 `int slop = dragSlopPx();` 后 `Math.abs(dx/dy) > slop`。
3. `dragSlopPx()` helper 对哨兵 `-1` 懒解析兜底，保证任何触摸都拿到正值（避免「阈值 -1 → `Math.abs(dy) > -1` 恒真 → 一切皆拖动」的反向失败）。

数据结构层修复（把「什么算拖动」的判据统一到平台单一真相源），非症状补丁：拖动仍可用（只是像所有原生控件一样，需移动超过 8dp 才起拖），点击判据回到平台标准。零破坏——按钮/拖动/位置持久化行为不变，只是把被误吞的点击还回来。

### 待验（真机）
Android 真机（如 CPH2747，高密度屏）：开有声书 → 显示悬浮字幕 → 让 Hibiki 退后台（悬浮窗仍在）→ 点字幕里的日文词 → 应弹出查词卡。若仍失败，再 `adb logcat | grep FloatingLyricService` 看 BUG-598 的 `startLookupActivity` 命中 PendingIntent / 直启 / 前台化哪条分支，据此判断是否为特定 OEM ROM 连 BAL opt-in 也封死（那时才需把弹窗改成第二个 overlay 窗、彻底不走 Activity）。
