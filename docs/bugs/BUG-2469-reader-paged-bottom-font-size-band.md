## BUG-2469 · 分页布局底部多留一个字号的空带
- **报告**：2026-09-11（用户：截图，「无论悬浮开关，上下都有一定边距；以前边距设 0 几乎贴顶/贴底，安全区之外不容许浪费显示面积」）
- **真实性**：✅ 真 bug（部分）。用户截图里的上下留白由三笔叠成：① 用户自己的页边距偏好 `margin_top` / `margin_bottom` = 5%（2026-09-06 15:33 写入，默认值是 0）；② 底栏挤压态下状态行与底栏各占一条（BUG-2467，已修）；③ **分页布局 padding-bottom 恒多加一个字号 F**——`fushi/lib/src/reader/reader_content_styles.dart:948`（`padding-bottom: calc(mb + ${fontSize}px + chrome-bottom-inset)`）、`:90`（`verticalColumnWidthCss` 相应 `- ${fontSizePx}px`）、`:272`（clip-path）、`:988`（`html::before` 覆盖条）、`:118`（Dart 代数镜像 `verticalColumnContentHeight`）。用户字号 43 ⇒ 列底边与底栏之间常驻一条 43px 谁也不占的空带，页边距设 0 也贴不到底。
  - 来历：TODO-734 之前列高建在 `--page-height` = V + O（O = bottomOverlap = 22）上，列底边 = V − cB + (O − F)，F 是用来抵消 +O 虚高的配对项；TODO-734 把基准改成纯 V 后 F 失去对象，代数守卫 `reader_vertical_pitch_invariant_test.dart:18` 甚至把它写成不变式「leak = −F（列底边永远比视口底高 F px）」。连续 / VN 布局的 padding-bottom 从来只含页边距 + chrome inset（`:1055` / `:1149`），只有分页多这一笔。
  - 顶部没有对应的 F：上留白 = 页边距 + chrome-top-inset（挤压态顶栏 48 / 悬浮态 0），无浪费。
- **[x] ① 已修复** — `23f66af41c`：四处 CSS 与 Dart 代数镜像一起去掉 F；列高 = V − mt − mb − cT − cB，与 padding 逐项镜像（TODO-729 的 `column-width == content-box`、pageStep == realPitch 恒等式不变），TODO-743 的 `max(F, …)` 坍塌地板保留。`tool/reader_pitch_headless/` 两个自带 CSS 复刻的探针同步。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_content_styles_test.dart`（竖排 / 横排 padding-bottom 与 column-width 都不再含字号项，并钉死不得退回 `+ 22px`）、`fushi/test/reader/reader_vertical_pitch_invariant_test.dart`（不变式 2 改为 leak ≡ 0：列底边贴底栏上沿，不随 F / cT / cB 漂移）。真渲染：headless Chrome 探针见提交说明。
- **备注**：用户的 5% 页边距不是 bug，是偏好；要贴边把「页边距 › 上 / 下」拨回 0 即可。
