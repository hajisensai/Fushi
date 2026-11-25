## BUG-4901 · 拼贴库页色块间距忽大忽小（没选过摆放时默认「散落」）
- **报告**：2026-11-15（用户：拼贴审查设计稿 #manga C1，截图红线）
- **真实性**：✅ 真 bug。没选过「色块摆放」时摆放跟着布局取默认，拼贴取的是散落：
  `fushi/lib/src/utils/adaptive/shell_style.dart:76`（基线 dd31e1dd0bb）
  `defaultFor(layout) => layout == ShellContentLayout.collage ? scattered : aligned`。散落给每块按序号加偏移和旋转，
  相邻块的可见间距随之忽大忽小，这是默认形态而不是用户选的效果。
- **[x] ① 已修复** — `ShellBlockArrangement.defaultFor` 一律返回规整（散落留作可选，用户显式选过的值不动）；
  `ThemeNotifier.shellBlockArrangement` / `shellBlockArrangementOf` 走同一个默认。设置页「色块摆放」恢复默认的目标随之是规整。
  提交哈希：收尾阶段统一提交后补。
- **[x] ② 已加自动化测试** — `fushi/test/utils/adaptive/shell_content_layout_pref_test.dart`
  （「C1：色块摆放没选过时一律规整」：两种布局下 `defaultFor` 与 `fromPref(null)` 都是规整）。
- **备注**：同条设计稿里的标题哈希后缀见 BUG-4898。散落本身的偏移幅度未改；实际库页观感需设备截图复核。
