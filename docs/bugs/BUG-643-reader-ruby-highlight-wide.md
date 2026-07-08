## BUG-643 · 阅读器竖排 ruby 有声书高亮条包含振假名导致变宽
- **报告**：2026-07-06（用户：wight）
- **真实性**：✅ 真 bug。第一张截图里有声书逐句高亮命中 `<ruby>` 基字时，背景条比普通正文列更宽；随后 2026-07-07 用户复测指出同一句后半段「の顔色が変わった」这类无振假名正文仍然偏宽。根因有两层：
  1. `hibiki/lib/src/reader/reader_content_styles.dart` 旧实现直接给 `ruby.hoshi-sasayaki-ruby-active` 整个 `<ruby>` 容器设置 `background-color`，竖排 ruby 容器盒子包含 `rt/rp` 注音轨，导致带振假名时背景横向扩到注音区域。
  2. `hibiki/lib/src/reader/reader_pagination_scripts.dart` 旧实现让 sasayaki 普通正文继续走 `::highlight(hoshi-sasayaki)`；改成 span 后，如果 span 仍继承正文 `line-height: 1.65`，iOS WebKit 竖排 inline 背景盒仍按行盒宽度绘制，所以无振假名片段也会比 ruby 基字 lane 宽。
- **[x] ① 已修复** — `hibiki/lib/src/reader/reader_pagination_scripts.dart` 不再为 sasayaki 普通正文设置 CSS Highlight，统一把普通文本包成 `.hoshi-sasayaki-cue` span，ruby 节点继续分流成 `ruby.hoshi-sasayaki-ruby-active`；`hibiki/lib/src/reader/reader_content_styles.dart` 统一用 `--hoshi-highlight-lane-color` + `background-image` 画正文基字窄条，并给 active 普通 cue span 加 `line-height: 1 !important`，避免继承正文行高把「の顔色が変わった」这类无 ruby 片段刷宽。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_content_styles_test.dart` 增加竖排 ruby/普通 cue span 的窄 lane 守卫，覆盖“普通正文不能直接 background-color，且 active span 必须 line-height: 1”；`hibiki/test/reader/ruby_highlight_guard_test.dart` 增加源码守卫，禁止 sasayaki 再回到 `CSS.highlights.set('hoshi-sasayaki', ...)`。
- **备注**：
  - 已跑 `flutter test --no-test-assets test/reader/reader_content_styles_test.dart --plain-name 'vertical sasayaki text spans draw only the base text lane'`，先红后绿。
  - 已跑 `flutter test --no-test-assets test/reader/reader_content_styles_test.dart test/reader/ruby_highlight_guard_test.dart test/reader/favorite_audio_highlight_overlap_test.dart test/reader/sasayaki_cue_mapping_drift_test.dart test/reader/diagnostic_logging_guard_test.dart`。
  - 已用 Xcode 27 beta 2 / iOS 27 在 HUAWEI 17 安装并启动 profile 包到书架；因 iPhone Mirroring 要求先锁定手机才能接管，尚未完成原书页目标句截图复测。
  - 仍需在 iOS 真机 HUAWEI 17（iOS 27 / Xcode 27 beta 2）profile 包复测原书页：播放到「田代裕也の顔色が変わった」时，`田代裕也` 与后半句无 ruby 文本都应是同样窄的正文基字条。
