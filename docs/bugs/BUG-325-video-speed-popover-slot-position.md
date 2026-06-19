## BUG-325 · 视频倍速浮层在顶栏/侧栏时仍往上弹（位置与按钮脱节）

- **报告**：2026-06-19（用户：B02 验收第 7 条）
- **真实性**：✅ 真 bug。倍速控制按钮可被自定义放进 9 槽位（TODO-274/399/421），但倍速轻浮层的弹出方向写死「向上」，按钮被放到顶栏 / 左右侧栏后浮层仍往按钮上方弹，与按钮真实位置脱节、可能被屏幕上边裁切。
  - 根因 1（写死向上）：`hibiki/lib/src/pages/implementations/video_hibiki_page.dart` 的 `_controlPopoverPlacementFor`——`speed` 分支无视 `sourceSlot` 恒返回 `targetAnchor: topCenter / followerAnchor: bottomCenter`（向上弹），且 `volume` 分支也只覆盖 `bottomLeft/bottomRight/默认`，未覆盖 `top*/screen*`。
  - 根因 2（slot 信息断链）：`_showSpeedMenu` / `_activateVideoControlButton`(speed) / 三处 `_controlPopoverAnchor(kind: speed)` 都没把 `sourceSlot`（与 `sourceItem`）传下去 → `_showControlPopover` 拿到 `sourceSlot == null` → placement 即使支持自适应也无 slot 可用。
  - 根因 3（横向 clamp 只给音量）：渲染块的 `resolveVideoControlPopoverPlacement` 旧门控 `kind == volume && ...`，倍速完全不走横向越界修正。
- **[x] ① 已修复** — commit 471602782
  - 新增纯函数 `videoControlPopoverDirectionForSlot(slot)`（`hibiki/lib/src/media/video/video_control_popover_placement.dart`）：底栏→上、顶栏→下、左侧栏→右、右侧栏→左，未知/隐藏/null→上（不引入回归）。
  - `_controlPopoverPlacementFor` 改为按方向纯函数映射 target/follower `Alignment` + 新增 `gapDirection`，音量与倍速共用同一套方向逻辑，覆盖全部槽位。
  - `CompositedTransformFollower` 的 `offset` 由写死 `Offset(dx, -gap)` 改为 `placement.gapDirection * gap + Offset(dx, 0)`（横向 `dx` 修正只在竖向弹时叠加，侧栏弹时横向由 gap 提供）。
  - `_showSpeedMenu` 接 `sourceSlot` 并透传 `sourceItem: speed`；`_activateVideoControlButton`(speed) 与三处倍速锚点（顶栏/底栏/侧栏 `_controlPopoverAnchor`）补传 `sourceSlot`/`sourceItem`。
  - `resolveVideoControlPopoverPlacement` 横向落点扩展覆盖 `top*/screen*`，并按方向算 `top`（新增可选 `height` 参数做越界 clamp，向后兼容）；渲染块横向修正门控放宽到音量+倍速同走。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_control_popover_geometry_test.dart`
  - 纯函数：8 槽位方向断言 + null/hidden 退回向上。
  - 几何：底栏浮层底边在按钮顶上方、顶栏浮层顶边在按钮底下方（不向上）、左侧栏在按钮右侧、右侧栏在按钮左侧、顶栏浮层竖向不越界。
  - 源码守卫：`videoControlPopoverDirectionForSlot(` / `gapDirection` / `placement.gapDirection * gap` 存在且旧 `offset: Offset(dx, -gap)` 已消失、倍速 click 路径携带 `sourceSlot`、横向 clamp 改 slot/targetRect 门控。
- **备注**：`flutter analyze` 0、`flutter test`（video 控制相关 847 通过 / 2 @Tags skip）。真机/真桌面待用户：把倍速按钮拖到顶栏、左右侧栏后点开，确认浮层分别向下/向右/向左弹且不被边缘裁切（焦点驱动验证见 docs/agent/integration-testing.md）。
