## BUG-1059 · 残缺的 x86 galgame helper 被当成已安装，自动转区失效

- **报告**：2026-07-24。用户反馈《屋上の百合霊さん フルコーラス》未自动转区，随后显示 “Game launch or early engine injection failed”；同机 Fate/stay night [Realta Nua] 也用于制卡链路回归。
- **真实性**：✅ 真 bug。用户机 `voice_hook/x86` 只有 injector、hook 与 Luna 文件，缺少 `LoaderDll.dll`、`LocaleEmulator.dll` 和许可证；安装器旧逻辑只检查 `hibiki_voice_injector.exe` 是否存在便直接放行。
- **[x] ① 已修复** — x86/x64 分别使用与发布工作流一致的完整文件清单；已有残缺安装会自动重新下载当前发布包修复，修复失败则阻止错误启动；解压后在写版本标记前同时校验发布包根目录与最终安装目录。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/galgame_helper_installer_test.dart` 覆盖 x86 Locale Emulator 清单、x64 架构隔离、Windows 文件名大小写、未知架构与“残缺安装先修复、后写 marker”的路径守卫。
- **备注**：用当前 x86 发布包真机验证《屋上の百合霊さん フルコーラス》能以正确日文标题启动并进入教程；Fate 的 KiriKiri 文本安全配置在配套 hook PR 中处理。

### 根因

`GalgameHelperInstaller.ensureInjector()` 原先把“注入器 exe 存在”等同于“helper 已完整安装”：

```dart
if (_injectorFile(arch).existsSync()) {
  await _maybeAutoUpdate(...);
  return true;
}
```

当在线 SHA 检查超时或失败时，`_maybeAutoUpdate` 按 Never break 策略继续沿用旧目录。该策略本身合理，
但旧目录可能来自早期四文件包，x86 缺少 Locale Emulator 运行库。结果是 UI 认为 helper 已就绪，
实际无法建立 CP932 环境，非 Unicode 游戏以乱码标题或黑屏启动，随后早期注入失败。

### 修复

- `galgameHelperRequiredFiles(arch)` 成为安装完整性的单一清单，与
  `.github/workflows/voice-hook-helper.yml` 的 x86/x64 产物对应。
- 完整安装仍保留 best-effort 静默更新；残缺安装不再走“离线也放行”，而是自动修复并复检。
- 下载包先校验 SHA-256，再校验 zip 根目录清单和落盘清单；只有全部通过才写 marker，避免把坏包记录成已安装版本。

### 验证

```text
flutter test --no-pub --no-test-assets \
  test/mining/galgame_helper_installer_test.dart \
  test/mining/galgame_helper_launch_guard_test.dart
# 30 passed

flutter analyze --no-pub \
  lib/src/mining/galgame_helper_installer.dart \
  test/mining/galgame_helper_installer_test.dart
# No issues found
```
