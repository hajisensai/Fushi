## BUG-1801 · 综合导入实测在iOS找不到字体fixture
- **报告**：2026-08-23（`iPhone pay` / iOS 26.6 物理机运行 `integration_test/comprehensive_imports_test.dart`）
- **真实性**：✅ 真 bug（测试基建）。`fushi/integration_test/comprehensive_imports_test.dart:98-107` 的字体 fixture 只枚举 Windows、macOS、Linux 宿主绝对路径；iOS App 沙盒不存在这些路径，真实 EPUB 导入通过后必然在 `_loadSystemFontBytes` 报 `No system TrueType font fixture was found`。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** — RED：物理机同一综合导入用例已到达书卡可见，随后在第 107 行 fail，exit 1；修复后同一用例验证字体落盘、启用及 `@font-face` CSS。
- **备注**：`fushi/pubspec.yaml:184` 已把 `assets/fonts/` 整目录随包，使用仓库内合法 TTF 作跨平台 fallback 比继续枚举平台系统字体路径更确定。
