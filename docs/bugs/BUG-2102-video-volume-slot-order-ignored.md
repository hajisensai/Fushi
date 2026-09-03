## BUG-2102 · 视频底栏音量按钮的槽内顺序被渲染端丢弃：拖动无效
- **报告**：2026-09-03（用户原话「视频自定义区域无效」——该表述指向哪块区域尚待用户确认，本条是排查中**确认存在**的两个缺陷之一，另一条见 BUG-2103）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/video_fushi_page.dart` 的 `_bottomSlotButtons`（修前）：

  ```dart
  final List<VideoControlItem> rawItems = _controlLayout.itemsIn(slot);
  return <Widget>[
    for (final VideoControlItem item in _slotChipItems(slot))   // 已排除 volume
      _buildBottomSlotButton(item, ...),
    if (rawItems.contains(VideoControlItem.volume))             // 只问「在不在」，不问「在第几位」
      _buildVolumeButton(controller, desktop: desktop, slot: slot),
  ];
  ```

  `_slotChipItems` 显式排除 `volume`，随后 volume 被**无条件追加到槽尾**，`itemsIn(slot)` 里它的真实下标整个丢掉。用户在底栏槽内怎么拖音量都零视觉变化（跨 bottomLeft↔bottomRight 是有效的，因为那换的是槽不是槽内位次）。

  **默认布局出厂就已分叉**：`currentChrome` 的 bottomRight 顺序是 `[volume, fullscreen, speed, customAction1..4]`（`video_control_customization.dart`），编辑器按真实下标画 chip → 音量排**第一**；播放器把它画在**最后**。桌面 + 移动两端都中（共用 `_centeredBottomControlBar`）。

  **为什么没被现有测试抓到**：`fushi/test/pages/video_volume_and_settings_dedupe_guard_test.dart` 把 `rawItems.contains(VideoControlItem.volume)` 这行**追加代码本身**断言成契约（`isTrue`），等于把 bug 锁进了守卫；`fushi/test/media/video/video_control_layout_test.dart` 是纯模型单测、从不渲染；`video_control_slot_renderer_defaults_test.dart` 文件头自陈「media_kit 控制条无法离屏渲染，只能用源码守卫」，其断言只能证明「调用了」不能证明「顺序对」。唯一断言顺序的 `video_header_button_order_guard_test.dart` 只覆盖 topRight 顶栏，底栏无等价守卫。

- **[x] ① 已修复** — 消除特殊情况：**一次遍历** `itemsIn(slot)`，按用户摆的真实顺序出控件，音量的分派放进循环体内。音量与其它按钮的差别只在**用哪个 widget 画**（它有浮层、要按槽位做几何避让），不在**画在第几位**，位置逻辑不该为它分叉。volume 仍不经 `_shouldRenderControlItem`（与旧行为一致：本次只改顺序、不改「画不画」）。
  - 提交：`ffdaa2a3f4`
- **[x] ② 已加自动化测试** — 两处守卫从「钉住 bug」改成「钉住不变式」：
  - `fushi/test/media/video/video_volume_row_test.dart`：断言底栏方法体含 `_controlLayout.itemsIn(slot)`（顺序取自真相源）+ `if (item == VideoControlItem.volume)`（循环体内按位分派），且**不得**再出现第二份「先画完 chip 再追加」的列表。
  - `fushi/test/pages/video_volume_and_settings_dedupe_guard_test.dart`：同上替换掉原先钉住追加写法的那条断言。
  - `test/media/video/` 3062 条 + `test/pages/` 3309 条通过。
- **备注**：同一函数里 `positionIndicator` 也恒排 bottomLeft 首位，但它 `isChipRenderable == false`、不进调色板、用户拖不动，故无用户可见症状，本轮未动。
