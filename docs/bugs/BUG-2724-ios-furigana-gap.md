## BUG-2724 · iOS 振假名离本行远、贴近上一行/上一列
- **报告**：2026-09-27（用户：「ios 的振假名离当前行远比较靠近上一行或者列，修复一下靠近当前行或者列（对应横屏或者竖排）」）
- **真实性**：✅ 真 bug（WebKit 专属）。根因 `fushi/lib/src/reader/reader_content_styles.dart` 的 `_webKitRubyAnnotationCss`：Apple 端只处理了注音盒在流中的高度（BUG-2472 的负 `margin-block-start`），没处理注音**位置**。
  - 机制：WebKit 的 ruby 布局把注音边框盒底贴在基字「内容区」顶（竖排是右缘）。Hiragino 的 ascent 比汉字墨迹顶高出一截，注音盒自身又带 `line-height: normal` 的半行距（WebKit 不理会 rt 上的 line-height，改 `line-height:1` 注音盒高仍是 11.7px），两截空白全落在注音与本行之间。
  - 实测（iOS 26.5 模拟器 Safari，真阅读器正文 CSS、quirks 模式、22px、行高 1.65，截图按像素量注音墨迹到两侧墨迹）：横排离本行 3.3px / 离上一行 5.3px，竖排离本列 3.0px / 离上一列 4.7px——注音偏向上一行一侧，与用户描述一致。
  - 排除项：`margin-block-start` 取 0 / −2em / −1lh 三种写法渲染逐像素相同（BUG-2482 备注里「−2em 不被钳会把注音往外推」的猜测不成立）；`position: relative` + `inset-block-start` 对 ruby-text 盒无效（1em 也不动）。
- **[x] ① 已修复** — （提交哈希见本分支）Apple 端注音盒加 `margin-block-end: -0.2em`：WebKit 中注音盒底 = 基字顶 − `margin-block-end`，负值把注音朝基字方向挪，逻辑属性一条规则同时覆盖横排（向下）与竖排（向左）。同一装置复测：横排本行 1.3 / 上一行 7.3px，竖排 1.0 / 6.7px；40px Hiragino Sans 本行 1.7 / 1.3px、行高 2.2 本行 1.3 / 1.0px，均不压基字。Blink（Android / Windows / Linux）注音本就贴基字，不发。
- **[x] ② 已加自动化测试** — `fushi/test/reader/vertical_ruby_line_box_contain_guard_test.dart` 新增「BUG-2724」用例：iOS / macOS × 横排 / 竖排生成的正文 CSS 必须在含 `rt` 的选择器块里有负 `margin-block-end`；Android / Windows / Linux 不得出现任何负 `margin-block-end`。钉不变式不钉数值。变异验证：删掉该声明后此用例变红。
- **备注**：CSS 生成层之外没有 iOS 真 app 的自动化像素门；复测装置是「真阅读器 CSS 落盘 → Mac 上 `python3 -m http.server` → `xcrun simctl openurl` 让模拟器 Safari 打开 → `simctl io screenshot` → 注音染红、按像素量墨迹间距」，同一 WebKit 与系统字体，但不是阅读器 WKWebView 本体。
