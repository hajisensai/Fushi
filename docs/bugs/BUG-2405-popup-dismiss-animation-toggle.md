## BUG-2405 · 滑动关闭弹窗的动画只能靠开墨水屏模式关掉，没有独立开关
- **报告**：2026-09-10（用户：滑动关闭弹窗是有个动画的，我需要添加一个功能是关闭弹窗这个动画需要关掉这个动画）
- **真实性**：✅ 真缺口 —— 松手后的「补间滑出屏外 / 弹回原位」（200ms easeOut）此前**唯一**的关闭
  途径是 `einkSafeDuration`（`adaptive_platform.dart:66`），即只有开「外观 › 墨水屏模式」才顺带归零。
  想要瞬时关闭就得连带吃下纯黑白主题 + 线式高亮，两件事被强行绑在一起。设置里既有的两项滑关设置
  （`lookup.enable_swipe_to_close` 管功能开不开、`reading_controls.dismiss_swipe_sensitivity` 管
  阈值）都不碰动画。补间落点有两处：`swipe_dismiss_wrapper.dart:79`（弹窗顶栏可拖区 + 独立查词窗
  整窗滑关）与 `dictionary_popup_layer.dart:1348`（弹窗正文横拖关）。
- **[x] ① 已修复** —— 新增偏好 `popup_dismiss_animation`（默认 **true** = 保持既有手感）+ 设置项
  「弹窗关闭动画」（`reading_controls.popup_dismiss_animation`，设置 › 查词，紧邻既有两项滑关设置，
  `ReaderPlacement(lookup, order 6)` 同时出现在阅读器快捷设置）。
  - 两处补间收进**唯一入口** `popupDismissAnimationDuration(context, duration)`
    （`swipe_dismiss_wrapper.dart`）：用户开关关掉 → `Duration.zero`；否则再过
    `einkSafeDuration`（墨水屏仍然归零）。两条来源正交，eink 不被用户开关覆盖。
  - **顺带修掉一处真的会「关了没用」的时序 bug**：两处原本都在 `didChangeDependencies` 里缓存
    `_controller.duration`，而那只在**依赖**（这里是 `Theme`）变化时重跑。用户在设置里翻开关只触发
    rebuild、不触发 `didChangeDependencies`，控制器会一直留着上一次的 200ms —— 开关要等到下次主题
    切换或弹窗重建才生效。改成**用时取值**：`_applyDismissDuration()` 在每次启动补间前一刻调用
    （wrapper 的 `_finishDrag`、detector 的 `_finishHorizontalDrag` / `_springBack`），两条来源都
    当场生效，不依赖任何重建时机。这条是写测试时被「同一条拖动」对照用例逼出来的。
  - 跟手期的 `Transform.translate` 不动 —— 手指按住时的实时跟随不是补间动画，去掉会让滑关失去方向
    反馈（沿用 BUG-2283 备注的结论）。`Duration.zero` 的 `animateTo` 当帧 complete，`onDismiss` 仍在
    完成回调里触发，关窗时序不变。
- **[x] ② 已加自动化测试** —— `fushi/test/widgets/swipe_dismiss_wrapper_test.dart` 新增 group
  「SwipeDismissWrapper『弹窗关闭动画』开关」5 条，判别力沿用同文件 eink 组的「只 pump 一帧」手法
  （补间还在时该帧不可能 dismiss，归零后当帧就 dismiss）：默认开着仍在补间、关掉当帧即 `onDismiss`、
  同一条拖动下两者结果必须不同（开关真的改变行为）、**eink 下即使开关开着也仍归零**（两条来源正交）、
  关掉且未过阈值时弹回已归位且不误关。`tearDown` 还原单例偏好，避免泄漏到同进程后续用例。
  判别力验证：临时摘掉 `popupDismissAnimationDuration` 里的开关分支 → 正好这 3 条新用例红、eink 那批
  仍绿；恢复后 23/23 绿（含既有 18 条）。
  另在 `test/settings/settings_schema_coverage_test.dart` 的 `kCoveredElsewhere` 登记本行（与兄弟行
  `lookup/Swipe dismiss sensitivity`、`lookup/Swipe to close popup` 同款理由：生效点是
  `AnimationController.duration`，既非 reader CSS 也非主题树，harness 无适用 T4 渲染探针）。
  `test/settings` + `test/i18n` 共 500 条绿、`stillUnaccounted=0`；`dictionary_popup_swipe_close_test`
  / `dictionary_popup_layer_test` / `reader_caret_scripts_test` 94 条绿；`flutter analyze` 零问题。
- **备注**：
  - i18n 经 `tool/i18n_sync.dart --add` 同步 17 种语言，`dart run slang` 重新生成。
  - **真机未验**：本机没有 Android 墨水屏设备，改动本身是纯 Flutter 侧补间时长，已由 widget 行为
    测试覆盖；真机只需确认设置项可见、翻动后滑关立即变瞬时。
  - 与 [BUG-2403](BUG-2403-eink-popup-touch-instant-scroll.md) 是同一批用户诉求的两半：那条管**上下
    滑动**（内容滚动瞬时化），本条管**侧滑关闭**（关闭动画可单独关）。
