## BUG-4237 · SRS 同步冲突弹窗在 debug 下不显示，只剩遮罩挡住复习页（FushiMarquee 的 LayoutBuilder 答不了 intrinsic）
- **报告**：2026-11-07（用户：phase4 互联实测，Windows debug host 进复习页只见变暗遮罩、弹窗不出来，`nav go home --pop` 才清掉，每次进复习页又回来；同一弹窗在 Linux release 构建正常显示）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/components/fushi_marquee.dart:394`（旧 `build` 直接返回 `LayoutBuilder`）。
  冲突弹窗 `showSrsProfileConflictDialog`（`fushi/lib/src/pages/implementations/srs/srs_sync_settings.dart:160`）的候选行是
  `FushiListTile`，标题 / 副标题是 `FushiMarquee`，它用 `LayoutBuilder` 判断一行放不放得下。对话框把正文包在
  `IntrinsicWidth` 里量宽：MD3 是 material_ui `AlertDialog`（`dialog.dart:955`），Apple 表单式面板是
  `fushi_glass_overlays.dart` `_buildAppleSheet` 的 `IntrinsicWidth`。intrinsic 查询问到 `LayoutBuilder`：
  debug 抛「LayoutBuilder does not support returning intrinsic dimensions」，对话框面板没有尺寸；之后每次指针事件
  命中测试再抛「Cannot hit test a render box with no size」。遮罩在对话框下面一层，命中测试在对话框那层就中断了，
  所以点遮罩关不掉。release 跳过断言、`LayoutBuilder` 答 0，弹窗能显示，但候选行量宽时按 0 宽算（布局照样是错的）。
  另一处同源错误：旧实现只拿 `style`（列表行里是 null）量字，没有用祖先 `DefaultTextStyle`（listTitle 16）和
  `textScaler`，按 14px 默认字判断溢出，给滚动版定的行高也不对。
  「每次进复习页都回来」不是独立的生命周期 bug：`nav go home --pop` 把弹窗路由弹出、返回 null，等于「稍后」，按设计
  下次进复习页再问（`srs_app_runtime.dart` `_maybeShowProfileConflict`，`_conflictDialogOpen` 防止弹窗开着时重复弹）。
  只是弹窗每次都画不出来，看上去像遮罩卡死。
- **[x] ① 已修复** — `FushiMarquee` 外套 `_MarqueeIntrinsics`（RenderProxyBox），由它按文字自然尺寸回答
  intrinsic（最大宽 = 一行放下全文的宽，最小宽 0，因为放不下就滚动；高恒为一行）和 dry layout / dry baseline，
  intrinsic 查询不再往下问到 `LayoutBuilder`。量字改用 `DefaultTextStyle.of(context).style.merge(style)` 加
  `MediaQuery.textScalerOf`（或 `textScaleFactor`）；放得下时 `Align(heightFactor: 1)` 恒为一行高，无界宽时按自然宽、不撑成
  无限宽。修在共享组件上，所有放进对话框的 `FushiListTile` / `FushiMarquee` 都受益（目前 `FushiListTile` 只有这一个调用点）。
  其余在 `FushiAlertDialog` 正文里用 `LayoutBuilder` 的对话框（texthooker / 漫画扩展商店 / galgame 抓取设置等）都给了
  `SizedBox(width:)` 定宽，紧宽约束会替它们回答 intrinsic 宽，不受影响。分支 `fix/srs-conflict-dialog-intrinsic`。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/srs_profile_conflict_dialog_intrinsic_test.dart`：用真实
  `showSrsProfileConflictDialog` 在 MD3 和 Apple 玻璃两种设计下各弹一次，断言没有 intrinsic 异常、候选行有尺寸、点得中、返回
  `SrsProfileConflictAdopt`；另有 `FushiMarquee` / `FushiListTile` 放在 `IntrinsicWidth` / `IntrinsicHeight` 下的尺寸
  断言（量字用继承样式）。修复前 5 条全部因「LayoutBuilder does not support returning intrinsic dimensions」失败。
  golden `list_tile_narrow.png` 重新生成：150 宽里「Dict」按实际字号放不下，以前被误判放得下、画成截断的「Di…」，现在走跑马灯。
- **备注**：真机复测**待补**。带修复的 Windows debug 构建已在隔离数据（phase4 host 隔离根的副本，FUSHI_TEST_ROOT）上启动并
  进入复习页：页面正常、没有残留遮罩；但副本里云同步没配置、互联同步关闭，冲突弹窗的触发条件（与配对客户端同步时检出
  profileNotLinked）复现不出来，没能在真 app 里看到弹窗本身。需要在 phase4 的 host + 客户端组合里重放一次同步，确认弹窗显示、
  候选行点得中。
