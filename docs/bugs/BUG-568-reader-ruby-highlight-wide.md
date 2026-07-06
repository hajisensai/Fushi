## BUG-568 · 阅读器竖排 ruby 有声书高亮条包含振假名导致变宽
- **报告**：2026-07-06（用户：wight）
- **真实性**：✅ 真 bug。截图里有声书逐句高亮命中 `<ruby>` 基字时，背景条比普通正文列更宽。根因：`hibiki/lib/src/reader/reader_pagination_scripts.dart:1235` 为规避 CSS `::highlight` 在 ruby 中双绘，故意把 ruby 文本分流成 `ruby.hoshi-sasayaki-ruby-active`；但 `hibiki/lib/src/reader/reader_content_styles.dart:518` 直接给整个 `<ruby>` 容器设置 `background-color`。竖排 ruby 容器的盒子包含 `rt/rp` 注音轨，所以有振假名时背景横向扩到注音区域。
- **[x] ① 已修复** — `hibiki/lib/src/reader/reader_content_styles.dart:545` 新增 ruby 基字窄条规则：ruby active class 只写 `--hoshi-ruby-highlight-color`，统一用 `background-image` 画背景；竖排限制为 `1em 100%` 并钉在 `left center`，横排限制为 `100% 1em` 并钉在 `left bottom`，不再给整个 ruby 容器刷背景。（本提交）
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_content_styles_test.dart:317` 增加竖排/横排 ruby 高亮 lane 守卫；红绿验证过旧 CSS 会红，修复后通过。
- **备注**：
  - 已跑 `flutter test --no-test-assets test/reader/reader_content_styles_test.dart`。
  - 已跑 `flutter test --no-test-assets test/reader/ruby_highlight_guard_test.dart test/reader/favorite_audio_highlight_overlap_test.dart`。
  - 已在 iOS 真机 HUAWEI 17（iOS 27 / Xcode 27 beta 2）profile 包实测：原书页播放到「田代裕也」带振假名句子时，背景条只覆盖正文基字，不覆盖右侧振假名轨。
