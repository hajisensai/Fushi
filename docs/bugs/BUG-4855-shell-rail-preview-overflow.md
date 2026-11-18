## BUG-4855 · 外观设置「侧栏样式」两张预览卡画出 OVERFLOWED 红黄条
- **报告**：2026-11-15（用户：Windows 桌面，设置 › 外观 › 主题，「侧栏样式」镂空脊 / 色脊两张选择卡的预览里都出现红黄条「OVERFLOWED BY …」）
- **真实性**：✅ 真 bug（本分支新加的预览，未进 develop）。根因 `fushi/lib/src/settings/shell_style_preview.dart` 旧 `_NotchRail.build` / `_SpineRail.build`（改前第 465–466 / 541–542 行 `itemHeight = math.max(4, railWidth * 0.12)`、`pad = railWidth * 0.16`）：侧栏示意的横条高与留白**只按盒子宽度**求（`railWidth = min(64, max(24, 宽 × 0.12))`），设置页选择卡的预览盒宽约 680、高只有约 58，railWidth 顶到 64 → 横条高 7.7、留白 10.2，竖排 Column 需要约 95dp，盒子只有 ~58dp，竖向溢出约 37dp。示意里没有真实文字，溢出完全来自宽度驱动的固定比例几何。
- **[x] ① 已修复** — 新增 `ShellRailPreviewMetrics.of(Size, ShellRailStyle)`（shell_style_preview.dart:427）按盒子**宽高一起**求几何：留白 ≤ 盒高 × 0.08，横条高钳到「(盒高 − 竖向留白) ÷ 竖向份数(+1 份余量)」（镂空脊 2.5 份留白 + 9 份横条，色脊 5 份留白 + 8.6 份），去掉 4dp 下限；`_NotchRail` / `_SpineRail` 只读这份几何。任意宽高比都不再溢出。另：设置页不再用整行大卡，改为行尾 80 × 40 的紧凑选择块（同一套示意）。提交哈希：未提交（委托方禁止 git 写操作）。
- **[x] ② 已加自动化测试** — `fushi/test/settings/shell_style_preview_layout_test.dart`：两种侧栏样式在 680×58（原始失败形状）/ 1400×40 / 66×38 / 240×120 盒子里收集 FlutterError 必须为空；设置页三行在 360 / 800 / 1460 宽下同样无 FlutterError。
- **备注**：需 Windows 真机肉眼复看（本轮未起 app，调试实例由主会话热重载）。
