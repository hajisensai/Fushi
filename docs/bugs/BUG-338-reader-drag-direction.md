## BUG-338 · 阅读器左键拖动翻页方向反·应与手机触屏跟手一致
- **报告**：2026-06-19（用户：TODO-597）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:2143-2145`（`_hoshiReaderMouseDragScrollBy` 的竖排分支）。

### 现象
桌面阅读器里「按住鼠标左键拖动」时，画面（内容）移动方向是反的，期望与手机触屏滑动「内容跟手」一致（鼠标往哪拖，内容那点就跟着往哪走，像拖地图/PDF）。

### 注意：与误判提交的区别
之前一轮误判成「鼠标滚轮方向」（提交 `b8a4d1fe9`，改的是 wheel 的 `e.deltaY` 判断 `reader_hibiki_page.dart` 滚轮路径）。那不是本问题。本问题是**左键按住拖动**的 drag-to-pan 路径，走的是注入 JS 的 `pointerdown/pointermove/pointerup` 状态机 → 连续模式下每帧 `_hoshiReaderMouseDragScrollBy(dx, dy)` 实时滚动内容，与滚轮无关。

### 根因（引入于 `8cc06d764` "fix(reader): add desktop mouse drag scrolling"）
连续模式（`hoshiContinuousMode`）下，左键拖动每帧调 `_hoshiReaderMouseDragScrollBy`（`dx = clientX - lastX`，鼠标增量）：
```js
function _hoshiReaderMouseDragScrollBy(dx, dy) {
  var vertical = !!(r && r.isVertical && r.isVertical());   // 阅读器只布局 vertical-rl
  var writingMode = window.getComputedStyle(document.body).writingMode;
  if (vertical) {
    var sign = (writingMode === 'vertical-rl') ? -1 : 1;     // ← 错误的特殊情况
    window.scrollBy({left: -dx * sign, top: 0, ...});        // vertical-rl 时 = scrollBy({left: dx})
  } else {
    window.scrollBy({left: 0, top: -dy, ...});               // 横排正确（跟手）
  }
}
```
drag-to-pan「内容跟手」的物理方向与书写方向无关，永远是：鼠标往右拖（dx>0）→ 内容往右移 → scrollLeft 减小 → `scrollBy({left: -dx})`。而 `sign=-1` 把它翻成 `scrollBy({left: dx})`（dx>0 → scrollLeft 增大 → 内容往左），方向反了。

交叉锚点：同文件已验证正确的 `paginate`（`reader_pagination_scripts.dart:1647`）里 vertical-rl 的 forward（下一页，露出左侧）走 `scrollBy({left: -amount})`（scrollLeft 减小=内容往右=露出左侧），与「跟手用 -dx」自洽。`isVertical()` 只判 `vertical-rl`，所以 `sign` 的 else(=1) 是死分支，`sign` 整体多余且有害——两个竖排方向正确答案都是 `-dx`，无需分支。横排 else 分支 `top: -dy` 本就跟手正确，不改。

不动 `onSwipe` 翻页方向，不动 `invertSwipeDirection` 开关（分页滑动翻页路径不受影响，手机分页滑动翻页方向本就对）。

### 影响范围
- 桌面（鼠标）+ 手机（触摸）连续模式拖动滚动 vertical-rl 竖排书：方向修正为跟手。横排/分页滑动翻页不受影响。

- **[x] ① 已修复** — 删除 `_hoshiReaderMouseDragScrollBy` 竖排分支的 `sign` 三目，统一为 `scrollBy({left: -dx})`。提交：`3ddc7d8b973ec16e6b7ed5e7da1783f3af60eb91`（分支 worktree-agent-a6d753361af4ed09e）
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_mouse_drag_scroll_guard_static_test.dart` 新增「vertical drag is finger-following (left: -dx, no writing-mode sign flip)」守卫：断言竖排分支为 `scrollBy({left: -dx`、不含 `sign`/`vertical-rl' ? -1`、横排分支保持 `top: -dy`。撤掉修复（恢复 sign 三目）转红。
- **备注**：纯几何/方向逻辑可静态守卫；视觉「画面跟手」需桌面真机/模拟器肉眼复测原始失败路径（连续模式竖排书左键拖动），待用户设备验证。
