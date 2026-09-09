## BUG-2353 · 日语转区将时区ID误作本地化时区名称
- **报告**：2026-09-08（用户要求复用 Fushi 转区启动）
- **真实性**：✅ 真 bug。原始 Rewrite Ver.2.00 已通过 CP932 与版本语言检查，仍在 GetTimeZoneInformation 名称检查失败。根因位于 native/galgame_hook/injector/locale_emulator_launch.h 的 BuildJapaneseLocaleEnvironment：将注册表时区键名 Tokyo Standard Time 同时写入两个本地化显示字段。
- **[x] ① 已修复** — 使用 Windows 日语 tzres.dll.mui 对应的标准时/夏令时显示名称，保留 UTC+9 与无夏令时规则；不修改系统时区。
- **[x] ② 已加自动化测试** — native/galgame_hook/tests/locale_emulator_launch_test.cpp 检查完整显示字段、偏移和规则；x86/x64 native CTest 通过。
- **备注**：2026-09-08 00:40:38 helper 65888 → 原始 Start.exe 74636 → 官方 StartMenu 50052 → SiglusEngine 70100，00:41:06 起进入 Key 标志及 Rewrite 标题菜单。只证明本地候选运行库启动通过，内嵌查词、语音、制卡尚未验证；正式随包组件未更新。
