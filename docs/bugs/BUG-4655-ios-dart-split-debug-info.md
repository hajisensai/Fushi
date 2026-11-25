## BUG-4655 · iOS 出包没拆 Dart 调试信息
- **报告**：2026-11-15（iOS 包体积调研）
- **真实性**：✅ 真问题。根因 `.github/workflows/release-desktop.yml` 的「Build iOS release app (no codesign)」与「Build signed iOS App Store IPA」两条出包命令（修复前约 :3234 / :3623）没带 `--split-debug-info`：Dart AOT 快照里留着 CodeSourceMap（iOS 真实画像 8.45 MB）等栈还原用的数据，arm64 A/B 实测 DWARF 栈形式比默认少 13.9%（约 −13.6 MB）。
- **[x] ① 已修复** — 两条命令加 `--split-debug-info`（未签名包 `build/ios/dart-symbols-unsigned`、TestFlight 包 `build/ios/dart-symbols-testflight`，两次构建不保证同一个 build id，分开存），各按发布序号上传 artifact `ios-dart-symbols-{unsigned,testflight}-<序号>`，保留期与 dSYM 同为 90 天、`continue-on-error`、不进 Release 资产。不加 `--obfuscate`：只多省 0.7 MB，而仓里有 `runtimeType.toString()` 判断（如 `ui_activity_probe.dart`），混淆后会坏。`docs/agent/build.md`「iOS 包体积与崩溃符号」写了 `flutter symbolize` 还原流程。
- **[x] ② 已加自动化测试** — `fushi/test/build/ios_release_size_guard_test.dart`「BUG-4655」组：两条命令带各自目录的 `--split-debug-info`、不带 `--obfuscate`；两个 Dart 符号上传步骤的名字 / 路径 / continue-on-error / 与对应 dSYM 步骤同保留期 / 位于构建之后。
- **备注**：
  - Mac 实测（Flutter 3.47.6，`flutter build ipa --release --no-codesign --split-debug-info=…`，含 BUG-4640）：App.framework/App 75,971,968 B（基线 108,188,368 B），拆出的 `app.ios-arm64.symbols` 57,013,919 B。
  - 代价：iOS release 包里的 Dart 栈是 DWARF 形式，诊断日志 / 反馈要按构建号取 symbols 后 `flutter symbolize`；`ui_activity_probe` 的调用点归因在 iOS release 上退化成原始帧。Android / 桌面没动。
