## BUG-3395 · VN 图文合并屏插图铺满整屏，同屏句子被挤出屏外
- **报告**：2026-10-14（用户：「ios的vn模式在这个位置直接看不到よく人を見ている并且图片位置有点歪但是这是右边距位9的情况下，如果正常边距……反正都是看不到よく人を見ている这句话，青春恋爱物语6的书」；修法定案时用户要求插图「要铺满」）
- **真实性**：✅ 真 bug，两个独立根因：
  1. `fushi/lib/src/reader/reader_visual_novel_scripts.dart`（修前 :1129）`buildScreens` 调 `attachMediaScreensToAdjacentText`（BUG-1244）把零宽纯图片屏并进下一段，合并屏 `splittable: false`（修前 :1216），`fitScreensToViewport` 对它不量不拆；插图又按整屏上限（`applyImageMaxVars`）排版，同屏竖排文字只能溢出到屏左外侧。やはり俺の青春ラブコメはまちがっている。6 的单图片章 `p-0021`（i-0115_01.jpg）经「合并图片页」（默认开，`_injectMergedChapterImages`）注入 `p-0022` 章首，紧跟的首段正是「……さすがだ、由比ヶ浜。よく人を見ている。」——有声书读这句时屏上只有图。
  2. 同文件 `applyImageMaxVars`（修前 :1099）按屏盒 `getBoundingClientRect()`（border-box，含左右用户边距 padding）× 0.95 定插图宽上限；右边距 9% 时插图比内容盒宽，向左溢出被裁、整体偏右（用户「图片位置有点歪」）。默认边距下内容盒恰好装得下，所以只在边距调大时出现。
- **[x] ① 已修复** — 纯图片屏保持独立一屏、铺满（删 `attachMediaScreensToAdjacentText` / `mergeAdjacentScreenParts`）；BUG-1244 的「自动播放不略过插图」改由跟随路径 `pauseAtCrossedMediaScreen` 承担：sasayaki 逐句跟随（`highlightSentenceAudioCue`）与选择器跟随（`highlightSelectorCue`）向前跨过图片屏、或音频跨章落地（`fromChapterStart`）而目标屏前有章首图时，若开了图片暂停（`pauseEnabled = imagePauseSec > 0`，与分页 / 连续 TODO-724 同一个门）先整屏停在图上并发 `onImageDetected`，Dart 暂停结束 `snapReaderToAudio` 再落到句子屏；`audiobook_bridge.dart` 把 `pauseEnabled` / `fromChapterStart` 传给这两个 VN 方法。`applyImageMaxVars` 改按扣掉 padding 的内容盒定上限。提交 b438d9a37e。
- **[x] ② 已加自动化测试** — `fushi/test/reader/vn_illustration_screen_test.dart`（+ `vn_illustration_screen_harness.mjs`，真 Chrome、生产 VN shell + 生产 VN CSS、iPhone 尺寸视口）：竖排 / 竖排右边距 9% / 横排下插图独占一屏且在屏盒内铺满、句子屏全部字形在屏盒内；开图片暂停时跟随先停图再落句、关图片暂停直达句子；章首插图跨章落地也先停图。变异对照：换回修前引擎红在「插图屏带着这句、6 段文字全在屏外」，去掉 padding 扣减红在「插图越出屏盒」。`vn_shell_smoke_test.dart` 原 BUG-1244 源码守卫改为钉「图片屏不并进文字屏 + 两条跟随路径都经 pauseAtCrossedMediaScreen」。
- **验证**：
  - iOS 模拟器 Safari（iPhone 17 Pro，iOS 26.5 真 WebKit），本书真实 `p-0022` 正文 + 真插图 + 生产引擎 + iOS 平台生成的生产 CSS：修前第 0 屏 = 插图 + 这句，句子贴左被裁（「る。」那列不见）；修后第 0 屏只有插图（默认边距 46–356 / 右边距 9% 32–342，都在内容盒内），第 1 屏句子 7/7 段字形在屏内。
  - Windows 真 app 离屏 runner（生产导入 + 开书，VN 竖排）：逐屏扫整章无正文越出屏盒，见 PR 描述。
  - 三种 view mode：改动只在 VN shell 与桥里多传给 VN 方法的两个参数（分页 / 连续的 `highlightSentenceAudioCue(cueId, reveal)` 不读多出的参数，`highlightSelectorCue` 只有 VN 实现），翻页 / 滚动的排版与跟随代码路径未变；真 app 探针同一章也以翻页、滚动模式各开一次。
- **备注**：取舍——图片暂停关闭（默认 0 秒）时，自动播放会直接越过插图屏，与翻页 / 滚动模式一致；想在自动播放时看到插图，需开启图片暂停。BUG-1244 的「图随相邻文字同屏」方案被本条取代（用户选择插图铺满）。
