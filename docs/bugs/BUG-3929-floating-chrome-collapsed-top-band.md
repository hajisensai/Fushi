## BUG-3929 · 顶栏收起后顶部留一条页面底色白边盖住背景
- **报告**：2026-11-01（用户：反馈 03cff3908u（Windows 截图）；同根因覆盖 Sb7jHbNO43（书架顶部白边））
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/components/fushi_floating_chrome.dart:887-919`：工具区收起后最外层遮罩仍按外壳让位区 `outer` 画页面底色实色段（topOpacity=1）+ 32 px 渐隐；此时让位区里没有任何可见工具（MD3 库页外壳标题条是收起态），纯色带只会盖住页面背景装饰。
- **[x] ① 已修复** — 最外层遮罩整段不透明度乘工具区弹簧显隐，完全收起时不画；展开 / 弹回时照常垫底。提交 6f3b2aec66。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_floating_chrome_collapsed_scrim_test.dart`（带非零让位区的收起 / 弹回）。
- **备注**：布局类：设备肉眼复测待补（Windows 视频库 / 书架页下滑后看顶部）。
