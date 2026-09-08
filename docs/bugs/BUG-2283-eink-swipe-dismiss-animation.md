## BUG-2283 · 墨水屏模式：查词弹窗滑动关闭仍有滑出/弹回补间动画
- **报告**：2026-09-08（用户：墨水屏模式查词滑动关闭弹框需要跟 hoshi reader Android 一样取消动画）
- **真实性**：✅ 真 bug —— 根因 `fushi/lib/src/utils/misc/swipe_dismiss_wrapper.dart:66`（原 `initState` 里把 `AnimationController.duration` 恒定钉成 `_kSwipeSlideDuration` = 200ms，全程没读过主题的 eink 扩展）。
  设置页 `eink_mode_hint` 明写「纯黑白主题、**无动画**」，`_BodySwipeDismissDetector`（弹窗正文横拖关，`dictionary_popup_layer.dart:1364`）与入场淡入（同文件 `:507`）都已按 eink 归零，唯独 `SwipeDismissWrapper` 漏了。
  该 wrapper 是顶栏可拖区（`dictionary_popup_layer.dart:831`）与无顶栏层整窗滑关（同文件 `:906`，app 外查词页 `popup_dictionary_page.dart:384` 的嵌套返回层）的唯一实现，所以墨水屏上从顶栏 / 独立查词窗滑关时，仍会画 200ms 的「位移滑出屏外 + 淡出」或「弹回原位」补间——慢刷新屏上就是一串灰阶残影。
- **[x] ① 已修复** — `SwipeDismissWrapper` 补 `didChangeDependencies`，用既有唯一入口 `einkSafeDuration(context, _kSwipeSlideDuration)` 设控制器时长（eink → `Duration.zero`），与 `_BodySwipeDismissDetector` 同款、跟随主题切换双向生效。`Duration.zero` 的 `animateTo` 当帧同步 complete，`onDismiss` 仍在完成回调里触发，关窗时序不变，只是不再画中间帧。顺带把 `dictionary_popup_layer.dart:1364` 手写的 `isEinkTheme ? Duration.zero : ...` 三元换成同一个 `einkSafeDuration` 助手（该助手的文档注释本就要求「别再手写三元」）。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/swipe_dismiss_wrapper_test.dart` 新增 group「SwipeDismissWrapper eink 取消滑关补间」3 条：过阈值松手后**只 pump 一帧**，非 eink 必须尚未 `onDismiss`（补间在跑）、eink 必须当帧就 `onDismiss`；外加 eink 未过阈值时弹回已归位（`Transform` 平移为 0）且不误关。判别力验证：临时移除 `didChangeDependencies` 后两条 eink 用例立刻红、非 eink 用例仍绿。
- **备注**：只动补间时长，跟手期的 `Transform.translate` + `Opacity` 保持不变（与 Android 侧 `_BodySwipeDismissDetector` 的既有 eink 处理一致——手指按住时的实时跟随不是补间动画，去掉会让滑关失去方向反馈）。
