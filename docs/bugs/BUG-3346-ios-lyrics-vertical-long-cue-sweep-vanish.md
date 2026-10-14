## BUG-3346 · iOS 竖排歌词播放时长句整列消失（BUG-3280 修复无效）
- **报告**：2026-10-14（用户：iOS 竖排歌词模式 + MD3 覆盖层主题，3 张截图，「播放暂停，在前后句的时候。比较长的句子就会显示不全」——播放中切到三列长句「委員会の仕事の他に…大変なことになるな。」时只剩中间一列，首尾两列空着；暂停后整句完整）
- **真实性**：✅ 真 bug，BUG-3280 的回退没修好。根因在逐字扫过规则（`fushi/lib/src/media/audiobook/lyrics_mode_html.dart:424-456`）：播放中当前句的行内 `.tx` 铺 `linear-gradient` + `background-clip: text` + 透明字色；WebKit 画不出折成多列的竖排行内盒上的 text 裁剪背景，于是文字透明、背景缺失。暂停时 `body.ly-paused` 让扫过规则失效，所以又完整了。BUG-3280 给 WebKit 加的 `-webkit-box-decoration-break: clone` 回退只按代码路径推断、没在 WebKit 上验过。
  - **iOS 模拟器 Safari 真 WebKit 像素探针**（iOS 26.5 / FushiProbe）：页面 = 生产 `LyricsModeHtml.generate`（竖排、MD3 主题参数、`platform: iOS`、截图里同几句 cue），URL 参数驱动 `__lyricsSetPlaying` / `__lyricsSetCue` / `__lyricsSetProgress`，`simctl io screenshot` 取屏上像素。
  - **二分**：修前 slice 与当前 clone 回退播放时都**整句消失**（模拟器上一列不剩，用户 iOS 上剩一列，坏法因系统版本而异），暂停完整；扫过进度 0% / 100% 一样消失；去掉当前句放大 transform 照样消失（不是合成层重绘问题）；单列短句正常；`.tx` 改 `display: inline-block` → 整句可见、扫过正常；去掉 text 裁剪也可见。横排多行长句在 WebKit 上 slice 扫过正常、按阅读顺序跨行，不受影响。
- **[x] ① 已修复** — `@supports not (box-decoration-break: slice)`（仅 WebKit 命中）回退块从 clone 改成竖排扫过规则下 `.tx { display: inline-block }`：渐变铺在一个原子盒上，各列同步自上而下扫过（与 BUG-3280 当初接受的「不跨列接续」代价相同）。Blink 不命中，保持跨列接续；横排不变。iOS 模拟器修后复测：扫过 0% / 30% / 动画走完、暂停、短句、横排六种状态当前句全部完整可见；inline-block 的列排布与暂停态（行内盒）逐列一致，播放 / 暂停切换不跳版。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_mode_feedback_batch_test.dart`（`BUG-3280 / BUG-3346` 组）：回退块只作用于竖排扫过选择器且写 `display: inline-block`，全页不再出现 `box-decoration-break: clone`，`.tx` 变 inline-block 的规则一律带 `.ly-vertical`；修前代码（clone）在该用例上红。像素层行为只能在真 WebKit 上验（CI 没有）。
- **备注**：
  - 未在 Fushi app 本体的 iOS 真机上复测，等用户在 iOS 上确认。
  - 若以后要在 WebKit 竖排恢复跨列接续，只能按列拆开渲染（每列一个盒、各算一段进度），不是改 box-decoration-break 能解决的。
