# 全平台自动更新 — 设计文档

> 日期：2026-06-04 · 分支：develop · 状态：设计待审
> 目标：把目前仅 Android 的应用内自动更新扩展到 5 平台（Android/Windows/Linux/macOS/iOS），
> 在各平台物理限制内做到「能自装的就自装、不能的就信息提示」。

## 0. 背景与现状（沿真实代码路径核查）

- **更新器**：`hibiki/lib/src/utils/misc/update_checker.dart` 的 `UpdateChecker`。
  `_check()` 第一行 `if (!Platform.isAndroid) return;` 把整条链门控为 Android-only。
  共享逻辑已具备且与平台无关：GitHub release 拉取（stable=`/releases/latest`，
  beta/debug=`/releases?per_page=1`）、版本比较 `isVersionNewer`、国内代理回退
  （`ghfast.top` / `mirror.ghproxy.com`）、通道（stable/beta/debug）、下载进度浮层
  `_downloadAndInstall`。
- **Android apply**：下载 ABI 匹配 APK → 原生 `HibikiChannels.update.invokeMethod('installApk')`
  → `MainActivity.java` FileProvider + `ACTION_VIEW`（带 HBK-AUDIT-058 路径校验）。
- **发布产物现状**：只有 `release.yml`（GitHub release 触发）构建签名 APK
  `hibiki-<version>-<abi>.apk` 上传到 GitHub Release。`build-multiplatform.yml` 对
  iOS/macOS/Linux/Windows **只做 debug 编译验证**，不打包/不签名/不上传。
  → **桌面/iOS 在 GitHub 上没有任何可下载安装包**，更新器无物可下。
- **偏好**：`updateNeverRemind` / `updateAutoInstall` / `updateBetaChannel` /
  `updateDebugChannel` 已在 `prefsRepo`（`app_model.dart:2725-2737`），复用。
- **设置 UI（BUG-013）**：更新设置分区当前网关为 `visible: (_) => Platform.isAndroid`
  （`settings_schema.dart` `_systemDestination()`）。本功能会**演进**该网关（见 §7）。
- **技术事实**：版本 `0.4.1+32`；Win 产物 `hibiki.exe`（ProductName "Hibiki"）、
  mac `hibiki.app`（PRODUCT_NAME `hibiki`）、Linux 二进制 `hibiki`（APPLICATION_ID
  `com.example.hibiki`）。macOS `Release.entitlements` 当前开沙盒
  （`com.apple.security.app-sandbox=true`）。

## 1. 平台可行性与既定决策

| 平台 | 能否应用内自装 | 方案 | 决策依据 |
|---|---|---|---|
| Android | ✅ 已实现 | 不变 | — |
| Windows | ✅ | Inno Setup 安装器，下载后运行→关 app→替换→重启 | 现先**不签名**上线（用户点 SmartScreen「仍要运行」），之后补 Authenticode（见附录 A） |
| Linux | ✅ | AppImage 单文件自替换+重启 | 无沙盒最干净；不碰 apt/sudo |
| macOS | ✅（**去沙盒**） | 下载 zip→替换 `/Applications/hibiki.app`→重启 | 用户决策：去掉 app-sandbox 换真自动更新；放弃未来 App Store 上架 |
| iOS | ❌ 平台禁止 | 「检查版本→打开发布页」信息提示 | Apple 禁止应用内下载安装可执行文件；无 App Store 身份 |

**用户既定决策**：①范围=完整分阶段（我建发布流水线+更新器）；②macOS 去沙盒做真自动更新；
③Windows 暂不签名、我提供取证书指引、后续补签；④macOS 无签名证书。

## 2. 分发模型与 asset 命名契约

沿用 GitHub Releases。CI 在 release 发布时为每平台打包并上传。**asset 命名是 CI 与
应用内更新器之间的唯一契约**，更新器按平台用稳定后缀匹配：

| 平台 | asset 名（`<v>` = 纯版本号如 `0.4.2`） | 更新器匹配规则 |
|---|---|---|
| Android | `hibiki-<v>-<abi>.apk`（现状不变） | ABI 子串匹配（现状） |
| Windows | `hibiki-<v>-windows-setup.exe` | 后缀 `-windows-setup.exe` |
| Linux | `hibiki-<v>-linux-x86_64.AppImage` | 后缀 `-linux-x86_64.AppImage` |
| macOS | `hibiki-<v>-macos.zip` | 后缀 `-macos.zip` |
| iOS | （无产物） | 无 → 打开 `html_url` |

匹配不到对应平台 asset 时，统一回退到「打开 release 页」（现有 `_showFallbackDialog`）。

## 3. 更新器重构（应用内）

把 Android-only 的硬门控替换为**按平台策略**，共享逻辑不动。

### 3.1 平台策略接口（纯 Dart，新增）

```dart
/// 每平台一个实现；负责"从 release assets 选包"和"应用更新"两件事。
abstract class PlatformUpdater {
  /// 当前平台是否支持应用内更新检查（iOS 仍 true，只是 apply=打开页面）。
  bool get isSupported;

  /// 从 GitHub release 的 assets 里挑出本平台可安装的下载 URL；
  /// 返回 null = 没有适配本平台的包（回退打开 release 页）。
  String? selectAsset(List<Map<String, dynamic>> assets);

  /// 应用已下载到 [file] 的更新（启动安装器 / 替换文件 / 重启）。
  /// iOS 实现不下载，直接 launchUrl(releasePage)，此方法不被调用。
  Future<void> apply(File file, String version);
}
```

- `AndroidUpdater`：`selectAsset`=现有 ABI 匹配；`apply`=现有 `installApk` 原生通道。
- `WindowsUpdater`：`selectAsset`=`-windows-setup.exe`；`apply`=`Process.start(installerPath, [/*silent or interactive*/])` 后 `exit(0)`，让安装器关旧进程→装→重启。
- `LinuxUpdater`：`selectAsset`=`.AppImage`；`apply`=把新 AppImage 写到当前 AppImage 路径（经 `APPIMAGE` 环境变量定位）旁的临时文件→替换→`chmod +x`→`Process.start(newPath)`→`exit(0)`。
- `MacUpdater`：`selectAsset`=`-macos.zip`；`apply`=解压 zip→`Process.run('ditto'/'unzip')`→用一段 `Process.start('/bin/sh', ['-c', swapScript])` 在 app 退出后替换 `/Applications/hibiki.app` 并 `open` 重启（去沙盒后允许）。
- `IosUpdater`：`isSupported=true`，`selectAsset` 总返回 null（无产物）→上层走「打开 release 页」。

桌面 apply **全部用 `dart:io Process`，无需新增平台通道**。

### 3.2 共享流程改动（`_check`）

- 删 `if (!Platform.isAndroid) return;`，改为 `final updater = _updaterForPlatform();`。
- 选包：`updater.selectAsset(assets)`；为 null → `_showFallbackDialog`（打开 release 页，
  iOS/无包桌面共用）。
- 下载：复用 `_downloadAndInstall` 的 HTTP+代理回退+进度浮层；下载目录改用各平台可写
  临时目录（`getTemporaryDirectory()`，现已用）。
- apply：`updater.apply(file, version)`。
- `autoInstall` 语义在桌面 = 直接下载并 apply；否则弹 `UpdateAvailableDialog`（现有）。
- 清理旧包 `_cleanupOldApks` 泛化为按平台后缀清理（apk/exe/AppImage/zip）。

### 3.3 不变量

- iOS 永不下载/执行外部二进制（平台合规铁律）。
- 桌面替换/重启失败要 `ErrorLogService.log` + SnackBar，不吞异常、不留半完成状态。
- 下载源校验：只接受 GitHub release 域名（+代理前缀）返回的 asset URL，apply 只对
  下载到自家临时目录的文件操作（对齐 Android 的 HBK-AUDIT-058 思路）。

## 4. CI 发布流水线（打包+上传）

在 release 发布时为每平台产出 §2 命名的 asset。建议**独立 job**（matrix 或分 job），
失败不互相阻塞，复用现有 `flutter-action` + `apply-patches.sh`。

- **Windows**（`windows-latest`）：`flutter build windows --release` →
  Inno Setup 脚本编译出 `hibiki-<v>-windows-setup.exe`（关运行中实例靠 AppMutex/CloseApplications，
  装到 `%LOCALAPPDATA%\Hibiki` 或 Program Files，建快捷方式，装后可勾选重启）→上传。
  **可选签名**：若提供 `WINDOWS_CERT_BASE64`/`WINDOWS_CERT_PASSWORD` secret，则
  `signtool` 签 exe；无 secret 则不签（先上线）。
- **macOS**（`macos-latest`）：`flutter build macos --release` →
  `ditto -c -k --keepParent build/macos/Build/Products/Release/hibiki.app hibiki-<v>-macos.zip`
  →上传。**去沙盒后**（§5）正常 ad-hoc 签名即可，不公证（用户首次仍可能需右键打开，
  但更新走应用内替换不经 Gatekeeper 二次拦——待 §8 真机验证确认）。
- **Linux**（`ubuntu-latest`）：`flutter build linux --release` →
  用 `appimagetool`（或 `flutter_to_debian`/手工 AppDir）打 `hibiki-<v>-linux-x86_64.AppImage`
  →上传。
- 版本号统一从 `pubspec.yaml` 抽取（沿用 `release.yml` 现有 `grep '^version:'` 逻辑）。

> 现有 `release.yml` 的 Android job 保持不变；新增桌面打包可放同一 workflow 的并列 job，
> 或新建 `release-desktop.yml`（同 `on: release: published`）。实现计划再定文件拆分。

## 5. macOS 去沙盒

- `hibiki/macos/Runner/Release.entitlements`：移除 `com.apple.security.app-sandbox`
  （保留 `network.client`/`network.server`/`device.audio-input`）。
- 影响评估：
  - ✅ 允许 app 内 `Process` 替换 `/Applications/hibiki.app` + 重启。
  - ❗ 放弃 Mac App Store 上架（商店强制沙盒）——已与用户确认接受。
  - ❗ 略降进程隔离；GitHub 分发的桌面 app 去沙盒是常见取舍。
- `DebugProfile.entitlements` 可保留沙盒（仅本地调试），或一并去除以贴近发布行为——
  实现计划阶段决定（倾向一并去除，避免 debug/release 行为分叉）。

## 6. iOS

- `IosUpdater.apply` 不实现下载/安装。
- 流程：检查到新版本 → `UpdateAvailableDialog`（现有）主按钮 = 打开 GitHub release
  `html_url`（现有 `_showFallbackDialog` 路径）。文案改为「前往下载」语义。
- 不引入任何下载/执行外部代码的路径（App Store 审核合规——即便当前不在商店，也守住
  合规边界，便于将来上架）。

## 7. 设置 UI 与 BUG-013 演进

- 现网关 `visible: (_) => Platform.isAndroid` 改为「在支持更新检查的平台可见」：
  Android/Windows/Linux/macOS 显示完整更新设置；iOS 显示精简版（仅「检查更新」动作 +
  通道选择可选，**不显示「自动安装」**因为 iOS 无法自装）。
- 具体：`updateAutoInstall` 开关网关为「桌面+Android」（iOS 隐藏）；通道/不再提醒可全平台。
- **BUG-013 守卫测试随之演进**：`test/settings/update_settings_android_only_guard_test.dart`
  的断言从「仅 Android 可见」改为「按平台能力可见 + iOS 不显示自动安装」。这是有意的不变量
  演进，不是回归。`update_checker.dart` 的数据侧断言从「`!Platform.isAndroid` 早退」改为
  「iOS 不执行 apply 下载」。

## 8. 测试策略（分层，对齐仓库范式）

- **版本比较 / asset 匹配**（纯 Dart 单测，最强层）：`isVersionNewer` 现有；新增
  各 `PlatformUpdater.selectAsset` 的单测（喂构造的 assets 列表，断言每平台选对后缀、
  无匹配返回 null）。
- **平台策略分发**（单测）：`_updaterForPlatform()` 在 mock 平台下返回正确策略；iOS
  策略 `selectAsset` 恒 null。
- **设置网关**（演进 BUG-013 守卫）：源码扫描 + 行为，断言 iOS 不显示自动安装、桌面显示。
- **apply 真实行为**：桌面 `Process` 启动安装器/替换文件属外部副作用，单测不可靠 →
  **设备/真机验证**（Win 离屏 `run_windows_itest.ps1` / Mac 跨机 `run_mac_itest.ps1` /
  Linux CI）登记集成 backlog，按仓库「声明修好前真机复测」纪律执行。
- **CI 打包**：在 workflow_dispatch 上先跑通各平台打包 job 产出 asset（不发 release），
  人工核验 asset 名与契约一致。

## 9. 分阶段交付

1. **Phase 0 — 发布流水线 + 契约 + 去沙盒 + 签名文档**：CI 桌面打包 job（产出 §2 asset）、
   macOS 去沙盒、Windows 签名 how-to（附录 A）。先让「有包可下」成立。
2. **Phase 1 — 更新器重构 + Windows**：`PlatformUpdater` 抽象、共享流程改造、`WindowsUpdater`
   全链路 + 单测 + Win 真机验证。
3. **Phase 2 — Linux**：`LinuxUpdater` AppImage 自替换 + CI 验证。
4. **Phase 3 — macOS**：`MacUpdater` zip 替换 + Mac 真机验证（去沙盒后 Gatekeeper 行为实测）。
5. **Phase 4 — iOS + 设置网关演进**：`IosUpdater` 信息提示、BUG-013 守卫演进、设置网关按
   平台能力分流。

每阶段独立可交付、独立验证，互不阻塞。

## 10. 风险与缓解

- **Windows 替换运行中 exe**：靠 Inno Setup 的 CloseApplications/AppMutex 关旧实例后替换；
  自定义 zip-swap 不可靠，故选安装器方案。
- **macOS 无公证 Gatekeeper**：去沙盒 + 应用内 `Process` 替换不经 Gatekeeper 重新评估
  （替换已批准过的 app）；首次安装仍需用户右键打开。需 Phase 3 真机确认替换后能正常启动。
- **Linux AppImage 路径定位**：靠 `APPIMAGE` 环境变量；若用户以非 AppImage 方式运行
  （如解包后直接跑）则回退「打开 release 页」。
- **代理/网络**：复用现有 `ghfast.top`/`ghproxy` 回退。
- **半完成状态**：apply 失败必须保留旧版本可用 + 记录错误 + 提示，不留坏档。

---

## 附录 A — Windows 代码签名（你问的「怎么弄」）

**先上线再补签**：Windows 安装器**可以不签名直接发布**，用户首次运行会看到 SmartScreen
蓝色弹窗「Windows 已保护你的电脑」→ 点「更多信息」→「仍要运行」即可。这不影响功能，
只是体验和信任度。

**要消掉警告，需要 Authenticode 代码签名证书**，两类：

| 类型 | 价格/年（约） | SmartScreen 信誉 | 存储 |
|---|---|---|---|
| **OV（组织验证）** | $200-400 | 需积累下载量才逐步消警告（冷启动仍可能弹） | 2023 起强制硬件 token/HSM |
| **EV（扩展验证）** | $300-600 | **立即获得 SmartScreen 信誉**，几乎不弹警告 | 强制硬件 token/HSM |

**主流签发商**：DigiCert、Sectigo（原 Comodo）、SSL.com、GlobalSign。个人开发者可选
SSL.com / Certum（Certum 对开源/个人较便宜，约 $80-150，云签名）。

**拿到证书后接 CI**：
1. 证书导出为 `.pfx`（或用云签名 API，如 SSL.com eSigner / Azure Trusted Signing——
   后者新出、按量计费、无需自管硬件 token，推荐）。
2. CI 加 secret：`WINDOWS_CERT_BASE64`（pfx 的 base64）+ `WINDOWS_CERT_PASSWORD`，或
   Azure Trusted Signing 的服务凭据。
3. 打包 job 里对 `hibiki-<v>-windows-setup.exe` 跑 `signtool sign /fd SHA256 /tr
   <timestamp-server> /td SHA256 ...`（§4 已留可选签名分支）。

**推荐路径**：先不签名发 Phase 1，跑通自动更新；并行去申请 **Azure Trusted Signing**
（最省心，无硬件 token），到手后加 CI secret 即自动签名，零代码改动。

## 附录 B — 受影响文件清单（预估）

- `hibiki/lib/src/utils/misc/update_checker.dart`（重构为平台策略）
- 新增 `hibiki/lib/src/utils/misc/platform_updater.dart`（策略实现，或拆分多文件）
- `hibiki/lib/src/settings/settings_schema.dart`（网关按平台能力演进）
- `hibiki/test/settings/update_settings_android_only_guard_test.dart`（守卫演进）
- 新增 `hibiki/test/utils/misc/platform_updater_test.dart`（asset 匹配/分发单测）
- `hibiki/macos/Runner/Release.entitlements`（去沙盒）
- `.github/workflows/release.yml` 或新增 `release-desktop.yml`（桌面打包+上传）
- 新增 Inno Setup 脚本 `hibiki/windows/installer/hibiki.iss`
- 新增 Linux AppImage 打包脚本/AppDir 配置
- i18n：新增更新相关 key（经 `i18n_sync.dart`，如「前往下载」iOS 文案）
