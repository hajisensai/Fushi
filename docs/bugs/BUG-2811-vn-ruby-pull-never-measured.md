## BUG-2811 · VN 模式注音拉力从未量成功（首屏无注音、换屏不重量），Klee One 注音离基字远
- **报告**：2026-09-30（BUG-2810 修复后按「小说阅读器问题三种 view mode 都要验」补验时发现，用户未单独报告）
- **真实性**：✅ 真 bug（WebKit，VN 模式专属）。根因 `fushi/lib/src/reader/reader_ruby_metrics_script.dart`（修前 `:107-120` 的触发点）：BUG-2779 的度量只在安装、字体就绪 / 加载完成、`#fushi-reader-style` 被替换时各量一次。VN 的 `detachChapterSource`（`reader_visual_novel_scripts.dart`）把整章挪进脱离文档的 `sourceRoot`，`body` 里只剩当前屏；开书那一屏常常没有注音（或舞台尚未渲染），这几次度量都在 `probeRuby` 找不到注音时空返回，此后 `renderScreen` 换屏不会再触发度量——`--fushi-ruby-pull` 从未写入，注音落回缺省拉力 0.1（按 Hiragino 标定），Klee One 这类内容区大的字体下注音离基字远、贴上一列（BUG-2779 的原症状在 VN 里一直没修到）。
  - 实测（iOS 26.5 模拟器，真 app，`integration_test/reader_ruby_pull_view_modes_probe_itest.dart`，俺ガイル真书 + Klee One 42px 竖排 + 行高 1.65）：VN 模式 `--fushi-ruby-pull` 为空，注音盒中心离基字中心 0.982em（翻页 / 滚动修好后都是 0.680em）。
- **[x] ① 已修复** — 度量脚本维护「还没为当前字体量成功」标记：安装时置上，量成功清掉，字体 / 样式变化重新置上；标记挂着时 `body` 子树的节点增删（VN 换屏、换章、懒加载）都会再排一次度量。量成功之后节点增删直接返回，不再碰样式与布局；`measure` 也先看 `body` 里有没有 ruby，没有就不读样式。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_ruby_metrics_behavior_test.js`（由 `reader_ruby_metrics_script_test.dart` 驱动）VN 场景：首屏无注音不写 → 换到仍无注音的屏不写 → 换到有注音的屏写 0.770 → 量成功后换屏不再探测 → 换样式后在无注音屏不写、下一张有注音的屏重新写。变异验证：去掉 body 观察者，「a screen with furigana gets measured」变红；去掉量成功后清标记，「once measured, screen swaps do not re-probe」变红。
- **备注**：
