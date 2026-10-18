## BUG-3514 · iPad 漫画阅读器双指缩放失灵、大滑动后突然放大到上限并卡死
- **报告**：2026-10-18（用户：iPad，「无法双指放大缩小漫画……双指被认为是单指滑动了，并且滑动幅度很大也会莫名修改大小」「会直接变成这种大小」「还会卡死啥都[点不了]」，截图为页面被放大到只剩人物脸部局部）
- **真实性**：✅ 真 bug（Chromium 复现；iOS 真机未复测）。手势全在 WebView 注入脚本 `fushi/lib/src/media/manga/manga_overlay_html.dart` 的 `_mangaGestureJs`（Flutter 侧无缩放组件，正文上方的 `Listener` 在 iOS 上直接 return）。触点表 `touchPts` 只在 pointerup / pointercancel 冒泡到 `document` 时删条目；手指按在随后被移出 DOM 的节点上（`__mangaReplaceOcr` 换 OCR 层、`_coverRemove` 拆覆盖翻页克隆层）时，松手事件派给脱离文档的节点、`document` 收不到，这根「幽灵指」永久留在表里：
  1. 下一次单指按下时表里有两点 → 被当成捏合开始，滑动越大指距变化越大，倍率冲到上限 400%；
  2. `pinchGuard` 要等表清空才解除，之后每次松手提前 return → 点击 / 翻页 / 唤出工具栏全部失效（卡死）；
  3. `_pinchGeom` 只取表里前两个 id，幽灵点恒在其中 → 真实双指只有一根参与计算，捏合失灵。
- **[x] ① 已修复** — 见本分支提交：触摸 `pointerdown` 且 `e.isPrimary`（规范：此刻屏上没有其它触摸指针 = 新一轮手势）时清空触点表并复位 `pinch` / `pinchGuard`；另修三指以上抬一指换对时按当前倍率重定捏合基准，避免倍率跳变。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_touch_pinch_js_test.dart` + `.js`：在真 Chromium 加载 `mangaWindowDocument` 完整文档、派发真实多指 PointerEvent，翻页与条带两种模式各一套（捏合放大不翻页 / 放大后单指平移 / 捏回 / 丢指后大滑动不缩放且能翻页 / 不卡死 / 捏合中途丢指 / 三指换对不跳变）。修复前红在 `big swipe after a lost finger must not zoom, got 4`；去掉重定基准一行的变异红在 `changing the pinch pair must rebase`。
- **备注**：待 iPad 真机复测。推测项：iOS WebKit 把松手派给脱离文档的原目标这一点未在 iOS 上实测；「双指完全缩放不了」是否全由幽灵指造成也无真机证据（无残留时 Chromium 里捏合正常）；修复依赖 iOS WebKit 的 `isPrimary` 合规。
