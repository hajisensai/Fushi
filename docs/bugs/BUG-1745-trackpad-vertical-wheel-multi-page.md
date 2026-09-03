## BUG-1745 · 纵向触摸板惯性绕过手势闸门，一次滑动连翻多页
- **报告**：2026-08-19（用户报「触摸板翻页」）
- **真实性**：✅ 真 bug。是 BUG-1342 / BUG-1380 两轮修复之后**仍然存在的残余**。

  **根因 A（主因）：闸门只对横向生效，纵向触摸板整段惯性漏光。**
  JS 侧按每个 tick 的主轴分类（`reader_fushi/webview.part.dart:1377-1385`，修前）：
  ```js
  var horizontal = Math.abs(e.deltaX) > Math.abs(e.deltaY);
  ...callHandler('onWheelPaginate', direction, horizontal ? 'horizontal' : 'vertical');
  ```
  Dart 侧闸门（`webview.part.dart:2178-2185`，修前）条件是 `axis == 'horizontal' && ...`。
  BUG-1342 的修复文档明写「纵向鼠标滚轮不进此 gate，保留原有固定窗口节流」——那个假设是
  **「纵向 = 鼠标滚轮」**。但 macOS 触摸板上下双指滑同样是纵向，惯性流持续 1~1.5 秒，全部落进
  `_paginate` 的固定 450ms 窗（`chrome.part.dart:102-109`，默认值见 `reader_settings.dart:458`）：
  1500ms / 450ms ≈ **一次上下滑翻 3 页**。设置里的滑块下限是 150ms
  （`settings_schema_reading.dart:629-631`），用户为了「跟手」调到下限就是**一次滑翻 10 页**。

  **根因 B（叠加）：轴分类是 per-tick、闸门是 per-axis，横滑里的漂移帧会漏出闸门。**
  同一次横向手势里个别 tick 会出现 `|deltaY| >= |deltaX|`（手指纵向漂移、惯性尾段轴向噪声），
  判据又是严格 `>`（`|dx| == |dy|` 也归 vertical），这些 tick 被标成 `'vertical'` →
  整条 `axis == 'horizontal' &&` 短路 → 直接进 `_paginate`，只受 450ms 窗管。于是一次横滑 =
  闸门放行 1 页 + 若干漂移 tick 在 450ms 后再各翻 1 页。
  弹窗滚动路径（`docs/bugs/BUG-701-touchpad-wheel-subpixel.md`）踩过同一个坑并已用
  「严格 `>` + 抖动余量」修掉，**阅读器分页路径当时漏了**。

- **[x] ① 已修复** — 提交见本分支。
  - `reader_fushi/webview.part.dart` JS 侧：
    - 主轴判据加抖动余量 `PAGED_WHEEL_AXIS_MARGIN = 6`：`absX > absY + MARGIN` 才算 horizontal
      （配方与 BUG-701 一致）。
    - 新增 `_isTrackpadWheel(e)`：`deltaMode !== 0` 排除真滚轮；分数像素增量 / 两轴同时非零 /
      `wheelDelta` 不是 120 的整数倍 → 判触摸板。**只用单事件可得的量**——JS 侧不能存手势状态
      （翻章会重建 document，这正是 BUG-1342 把闸门放进 Dart 的理由），时间维度的聚合仍由
      跨 document 持久的 `ReaderWheelGestureGate` 负责。
    - `onWheelPaginate` 增加第三个参数 `'trackpad' | 'mouse'`。
  - Dart 侧闸门判据从 `axis == 'horizontal'` 改为 `pointerKind == 'trackpad'`：
    真正要区分的从来不是轴，而是「离散 tick（鼠标，一格一页是正确期望）」与
    「连续惯性流（触摸板，一次滑动一页）」。纵向触摸板从此进闸门，纵向鼠标滚轮零变化。
    `args.length <= 2` 时按「横向即触摸板」缺省推断，与改动前行为逐字一致（向后兼容老 shell）。
  - BUG-1380 的 `canTurnPage: !_paginationInFlight` 契约原样保留（换章加载期的 tick 只查询不认领）。

- **[x] ② 已加自动化测试** —
  - `fushi/test/reader/trackpad_wheel_classification_test.dart`（新建）：闸门在**纵向**输入上的
    行为不变量 —— 1.5 秒惯性（94 拍 ×16ms）只翻 1 页（旧实现翻 3 页）；间隔调到下限 150ms 仍是
    1 页（旧实现 10 页）；两次滑动间有完整静默则各翻 1 页；离散慢速 tick（600ms 间隔）各自成手势
    5 次；BUG-1380 的「翻不动页的 tick 不认领手势」契约在纵向上同样成立。
  - `fushi/test/reader/reader_mouse_paging_boundary_guard_static_test.dart`：主轴守卫更新为
    带抖动余量的形态（`absX > absY + PAGED_WHEEL_AXIS_MARGIN`），新增「必须回传输入设备类型」
    与「闸门判据必须是 `pointerKind == 'trackpad'`、**禁止**退回 `axis == 'horizontal' &&`」两条。
    该文件原有的 21 条 wheel 守卫（方向归一、arm-then-fire、不读 `invertSwipeDirection`、
    `canTurnPage` 实参等）全部保留未改。
  - 验证：`flutter test test/reader/ --no-pub` 全绿。

- **备注**：**须 Mac 真机复验**（`_isTrackpadWheel` 的启发式依赖真实 WheelEvent 的
  `deltaMode`/`wheelDelta`，headless 造不出）：上下双指滑一次应恰好翻一页；鼠标滚轮一格仍应
  一页；横滑不再出现「1 页 + 补翻」。
  **本轮未动**（属于产品缺口而非本 bug 的时序根因，需单独立项）：滚轮翻页方向不读
  `invertSwipeDirection`、也不读书写方向 rtl，与触摸滑动路径（`swipeLeftIsForward(invert:, rtl:)`）
  方向不一致且无开关可调；BUG-1380 备注里也记过这条。
  与 [[BUG-1744]] 同为本轮 macOS 阅读器体感问题，根因无关、可独立回滚。
