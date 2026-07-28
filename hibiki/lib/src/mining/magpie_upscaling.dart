/// 内置 Magpie 窗口超分的**纯逻辑层**（阶段二）。
///
/// 这一层刻意不碰 `dart:io`、不碰 FFI、不碰 UI：三态开关的后端裁决、Magpie 配置文件的
/// profile 增量改写全部是纯函数，可在任意平台单测。真正的进程/窗口/文件操作在
/// `magpie_upscaling_service.dart`。
///
/// 设计与调研结论见 `docs/specs/2026-07-26-magpie-upscaling-design.md`。
library;

import 'package:flutter/foundation.dart';

/// Magpie 主窗口类名。用来探测「用户机器上已经跑着一个 Magpie」。
const String kMagpieMainWindowClass = 'Magpie_Main';

/// Magpie 的单实例互斥体名（`src/Shared/CommonSharedConstants.h`）。
///
/// 探测「已在运行」比找主窗口更可靠：`-t` 静默启动时根本没有主窗口，但互斥体一定在。
const String kMagpieSingleInstanceMutex =
    'Global\\{4C416227-4A30-4A2F-8F23-8701544DD7D6}';

/// Magpie 缩放窗口类名（native 侧联动与诊断用）。
const String kMagpieScalingWindowClass =
    'Window_Magpie_967EB565-6F73-4E94-AE53-00CC42592A22';

/// 广播消息名：缩放状态变化。`RegisterWindowMessage` 的入参。
const String kMagpieScalingChangedMessage = 'MagpieScalingChanged';

/// 广播消息名：请求已运行实例退出。**注册串就是这个字面量**，不是 `MagpieQuit`。
const String kMagpieQuitMessage = 'WM_MAGPIE_QUIT';

/// 静默启动参数：不建主窗口、只驻托盘（`CommonSharedConstants.h` 的
/// `OPTION_LAUNCH_WITHOUT_WINDOW`，消费点 `App.cpp:188`）。
const String kMagpieSilentLaunchArg = '-t';

/// Magpie 的 `AutoScale::Fullscreen`（`src/Magpie/Profile.h:29-34` 枚举第 1 项）。
///
/// **必须用全屏、不能用窗口化**：窗口模式的 `WM_WINDOWPOSCHANGED` 里有个 OS bug 兜底会
/// 主动把焦点抢回源窗口（`ScalingWindow.cpp:816-823`），查词浮窗会被踢掉。
const int kMagpieAutoScaleFullscreen = 1;

/// `AutoScale::Disabled`。
const int kMagpieAutoScaleDisabled = 0;

/// 我们建的 profile 的名字前缀。
///
/// 🔴 **这是持久化契约，不是显示细节**：启动期对账（`reconcileOrphansOnStartup`）靠它
/// 认出上一次进程崩溃 / 被 `exit(0)` 快杀时留下的孤儿 profile。改了前缀 = 认不出旧版本
/// 写过的那些，用户机器上会永久留着一条「双击游戏就自动全屏超分」的规则。
const String kMagpieHibikiProfilePrefix = 'Hibiki: ';

/// 用户可选的超分策略（三态）。
///
/// 与 `anime_download_config.dart` 的 `auto/builtin/external/off` 同范式，但这里**没有
/// builtin/external 二选一**：Magpie 只有一份，区别只在「谁装的」。三态就够。
enum MagpieUpscalingMode {
  /// 自动：优先用机器上已有的 Magpie；没有就按需下载我们的自编产物（需用户确认）。
  auto,

  /// 只用已装的：机器上没有 Magpie 就直接不超分，**绝不联网**。
  installedOnly,

  /// 关闭。
  off,
}

/// 没有为这个游戏设过档位时的兜底档。
///
/// 🔴 **必须是 `off`**（BUG-1191）：超分是**每个游戏各自**的开关，存在 galgame 库那一行
/// 上，缺省是空串。空串、认不出的旧值、以及压根不在库里的游戏（窗口附着路径没有稳定
/// 游戏身份）全部落到这里 —— 宁可不超分，也不能替用户默默打开一个吃 GPU 的东西。
const MagpieUpscalingMode kMagpieDefaultUpscalingMode = MagpieUpscalingMode.off;

/// 偏好里持久化用的稳定字符串。
///
/// **不要用 `enum.name` 或 index**——重排或插入枚举项会静默毁掉所有用户的旧设置。
String magpieUpscalingModeToKey(MagpieUpscalingMode mode) {
  switch (mode) {
    case MagpieUpscalingMode.auto:
      return 'auto';
    case MagpieUpscalingMode.installedOnly:
      return 'installed_only';
    case MagpieUpscalingMode.off:
      return 'off';
  }
}

/// 反解。null / 空串（没设过）和认不出的字符串（旧版本写坏、手改数据库）**一律**回落到
/// [kMagpieDefaultUpscalingMode]。
///
/// 刻意**不**区分「没设过」和「设成了关闭」：两者对这一局的行为完全一样（不超分），
/// 多分一态就等于多一个只在 UI 文案里体现、却要在整条链路上传递的特殊情况。
MagpieUpscalingMode magpieUpscalingModeFromKey(String? key) {
  switch (key) {
    case 'auto':
      return MagpieUpscalingMode.auto;
    case 'installed_only':
      return MagpieUpscalingMode.installedOnly;
    default:
      return kMagpieDefaultUpscalingMode;
  }
}

/// **纯函数**：把「本局的启动 exe」+「库里那一行存的档位串」合成本局要用的档位。
///
/// [launchExe] 是本次会话的启动 exe 全路径，也是 galgame 库那一行的 `exePath` ——
/// 用户在库里右键改的就是同一行，两边同一个真值，不会漂。
/// [storedModeKey] 是查到的那一行的档位串；查不到那一行（游戏不在库里）传 null。
///
/// 🔴 每一条查不到的路径都落到 [kMagpieDefaultUpscalingMode]（关闭）：
/// - `launchExe` 为空 = 窗口附着捕获，没有稳定游戏身份，**不猜**；
/// - `storedModeKey` 为 null/空 = 这个游戏没设过。
/// 反过来兜底成 auto 就等于替用户默默打开一个吃 GPU 的东西，而他既没同意过、也不
/// 知道该去哪关。
MagpieUpscalingMode resolveSessionUpscalingMode({
  required String? launchExe,
  required String? storedModeKey,
}) {
  if (launchExe == null || launchExe.isEmpty) {
    return kMagpieDefaultUpscalingMode;
  }
  return magpieUpscalingModeFromKey(storedModeKey);
}

/// 裁决结果：这次会话到底走哪条路。
enum MagpieBackend {
  /// 用户关掉了，或非 Windows（galgame 只做 Windows）。
  off,

  /// 用机器上已有的 Magpie（用户自装的，或我们之前装的）。
  installed,

  /// 需要先下载我们的自编产物（要弹确认框）。
  needsDownload,

  /// 想用但用不上：`installedOnly` 且机器上没装。静默降级，不打扰用户。
  unavailable,
}

/// **纯函数**：三态开关 + 探测结果 → 本次会话的后端。
///
/// 优先级刻意是「已装 > 下载」：用户机器上已有 Magpie（自装的官方版，或我们上次装的）时
/// 直接用，绝不为了用自己的产物而重复下载 10MB。
MagpieBackend resolveMagpieBackend({
  required MagpieUpscalingMode mode,
  required bool isWindows,
  required bool installedAvailable,
}) {
  if (!isWindows) return MagpieBackend.off;
  switch (mode) {
    case MagpieUpscalingMode.off:
      return MagpieBackend.off;
    case MagpieUpscalingMode.installedOnly:
      return installedAvailable
          ? MagpieBackend.installed
          : MagpieBackend.unavailable;
    case MagpieUpscalingMode.auto:
      return installedAvailable
          ? MagpieBackend.installed
          : MagpieBackend.needsDownload;
  }
}

/// 为什么这次没能写自动缩放 profile。**每一项都是可降级的**：一律退回「只启动 Magpie，
/// 让用户自己按热键（默认 Win+Shift+A）」，绝不让会话启动失败。
enum MagpieProfileSkipReason {
  /// 配置结构与我们已验证的 schema 不符：没有 `profiles` 数组，或第 0 项不是对象。
  schemaMismatch,

  /// 预热失败：Magpie 没能及时把默认配置（含 `scalingModes`）生成出来。
  ///
  /// 这是「第一次用」路径上唯一可能剩下的降级原因 —— 我们装完写的是 0 字节便携标记，
  /// 必须先静默跑一次 Magpie 让它自己生成完整配置，才谈得上写 profile。
  bootstrapFailed,

  /// `scalingModes` 缺失或为空：此时任何 profile 的 `scalingMode` 都会被钳到 -1，
  /// 缩放必报 `InvalidScalingMode`（`AppSettings.cpp:990-993` → `ScalingService.cpp:324`）。
  noScalingModes,

  /// 游戏窗口的 exe 路径或窗口类名拿不到。两者**都不允许为空**：空了整条 profile 会被
  /// `AppSettings::_LoadProfile` 直接丢弃（返回 false）。
  missingWindowIdentity,

  /// 机器上已经跑着一个不是我们起的 Magpie：我们有意不碰它的配置（位置未知、且它退出时
  /// 会整份回写覆盖我们的改动），也不替用户关掉重开。
  externalInstance,

  /// 目标是 Hibiki 自己 —— 硬禁令，见 [magpieProfileTargetAllowed]。
  forbiddenTarget,

  /// 已经是想要的状态，什么都不用做。
  alreadySatisfied,
}

/// [magpieConfigWithAutoScaleProfile] / [magpieConfigWithAutoScaleDisabled] 的结果。
@immutable
class MagpieProfileWriteResult {
  const MagpieProfileWriteResult.applied(Map<String, dynamic> this.config)
      : skipReason = null;

  const MagpieProfileWriteResult.skipped(
    MagpieProfileSkipReason this.skipReason,
  ) : config = null;

  /// 改写后的完整配置；跳过时为 null。
  final Map<String, dynamic>? config;

  /// 跳过原因；成功时为 null。
  final MagpieProfileSkipReason? skipReason;

  bool get applied => config != null;
}

/// profile 的三元身份：`(packaged, pathRule, classNameRule)`。
///
/// 与 Magpie 自己的匹配/去重判据一致（`ProfileService.cpp` 的 `_GetProfileForWindow`
/// 与 `TestNewProfileImpl`）：三者全等才算同一条。
///
/// 🔴 **窗口类名不是可选项**。`_GetProfileForWindow` 先比 `classNameRule` 再比 `pathRule`
/// （`ProfileService.cpp:220-222`，类名比取 exe 路径快得多所以放前面）——只写路径不写类名
/// 的 profile 永远匹配不上任何窗口，是一条静默的死规则。
///
/// 🔴 **大小写敏感、不做路径规范化**：Magpie 用的是裸 `std::wstring ==`
/// （`ProfileService.cpp:246`），没有 `_wcsicmp`、没有 `GetFullPathName`。我们必须原样照做，
/// 路径必须来自与 Magpie 同源的 `QueryFullProcessImageNameW`。
@immutable
class MagpieWindowIdentity {
  const MagpieWindowIdentity({
    required this.executablePath,
    required this.windowClassName,
  });

  /// 游戏窗口所属 exe 的**完整路径**。
  final String executablePath;

  /// 游戏主窗口的类名（`GetClassNameW`）。
  final String windowClassName;

  bool get isComplete =>
      executablePath.trim().isNotEmpty && windowClassName.trim().isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is MagpieWindowIdentity &&
      other.executablePath == executablePath &&
      other.windowClassName == windowClassName;

  @override
  int get hashCode => Object.hash(executablePath, windowClassName);

  @override
  String toString() =>
      'MagpieWindowIdentity($executablePath, $windowClassName)';
}

/// **纯函数守卫**：这个 exe 路径能不能建 autoScale profile。
///
/// 唯一的硬禁令：**绝不给 Hibiki 自己建自动缩放 profile**。Magpie UI 层每 50ms 轮询前台
/// 窗口，命中任何 `autoScale != Disabled` 的 profile 就 `force=true` 重启缩放
/// （`ScalingService.cpp:42-45`、`:250-273`）。给 Hibiki 建了，查词浮窗/主窗口一到前台就
/// 会把 galgame 的缩放踢掉，两个窗口来回打架。
///
/// [hibikiExecutablePath] 传 `Platform.resolvedExecutable`。比较**忽略大小写**（Windows
/// 路径语义），比 Magpie 自己的匹配更严 —— 这里宁可多拒也不能漏放。
bool magpieProfileTargetAllowed({
  required String targetExecutablePath,
  required String hibikiExecutablePath,
}) {
  final String target = targetExecutablePath.trim().toLowerCase();
  if (target.isEmpty) return false;
  final String self = hibikiExecutablePath.trim().toLowerCase();
  if (self.isEmpty) return true;
  return target != self;
}

/// **纯函数**：在既有 Magpie 配置上增量加一条「对该游戏窗口自动全屏超分」的 profile。
///
/// 这是**无契约行为**（Magpie 从没承诺 config.json 的格式稳定），所以每一步都先验证再动手，
/// 任何不符预期都返回 skip 而不是猜着写。调用方收到 skip 只需退回「只启动不配置」。
///
/// 已核对的 schema 硬事实（`hajisensai/Magpie` @ 上游 v0.12.1 基线）：
/// - 顶层键是 `profiles`（不是 `scalingProfiles`），**数组第 0 项是默认 profile**，它没有
///   name/pathRule 等字段（`AppSettings::_LoadProfile` 的 `isDefault` 分支跳过全部身份字段）。
/// - 非默认 profile 的 `name`（trim 后非空）/ `packaged` / `pathRule` / `classNameRule`
///   **缺一不可**，任一缺失或为空 → `_LoadProfile` 返回 false → 整条被丢弃。
/// - `autoScale` 是 **uint 枚举**（0=Disabled/1=Fullscreen/2=Windowed），不是 bool。
/// - `scalingMode` 是 `scalingModes` 数组的**索引**；越界或缺失会被钳到 -1，而 -1 让缩放
///   直接报 `InvalidScalingMode`。所以必须有非空 `scalingModes` 且索引有效。
/// - **没有 `scalingFlags` 这个 key**（拆成 `3DGameMode` / `captureTitleBar` /
///   `adjustCursorSpeed` / `disableDirectFlip` 四个 bool），我们一个都不写 —— 缺省即上游默认。
///
/// 只写「让它跑起来」的最小字段集：其余几十个字段（captureMethod / cursorScaling /
/// cropping / graphicsCardId …）全部留空由 Magpie 用自己的默认值填，我们不猜。
MagpieProfileWriteResult magpieConfigWithAutoScaleProfile({
  required Map<String, dynamic> config,
  required MagpieWindowIdentity identity,
  required String profileName,
  required String hibikiExecutablePath,
}) {
  if (!identity.isComplete || profileName.trim().isEmpty) {
    return const MagpieProfileWriteResult.skipped(
      MagpieProfileSkipReason.missingWindowIdentity,
    );
  }
  if (!magpieProfileTargetAllowed(
    targetExecutablePath: identity.executablePath,
    hibikiExecutablePath: hibikiExecutablePath,
  )) {
    return const MagpieProfileWriteResult.skipped(
      MagpieProfileSkipReason.forbiddenTarget,
    );
  }

  final Object? scalingModes = config['scalingModes'];
  if (scalingModes is! List || scalingModes.isEmpty) {
    return const MagpieProfileWriteResult.skipped(
      MagpieProfileSkipReason.noScalingModes,
    );
  }

  final Object? rawProfiles = config['profiles'];
  if (rawProfiles is! List ||
      rawProfiles.isEmpty ||
      rawProfiles.first is! Map) {
    return const MagpieProfileWriteResult.skipped(
      MagpieProfileSkipReason.schemaMismatch,
    );
  }
  final Map<Object?, Object?> defaultProfile =
      rawProfiles.first as Map<Object?, Object?>;

  // 缩放模式索引沿用默认 profile 的选择（用户在 Magpie 里挑过什么就用什么）；默认 profile
  // 自己越界或为 -1 时回落到 0（`scalingModes` 上面已确认非空）。
  final Object? defaultScalingMode = defaultProfile['scalingMode'];
  final int scalingMode = (defaultScalingMode is int &&
          defaultScalingMode >= 0 &&
          defaultScalingMode < scalingModes.length)
      ? defaultScalingMode
      : 0;

  final List<Object?> profiles = List<Object?>.from(rawProfiles);
  final int existing = _indexOfProfile(profiles, identity);
  if (existing >= 0) {
    final Map<Object?, Object?> entry =
        profiles[existing]! as Map<Object?, Object?>;
    if (entry['autoScale'] == kMagpieAutoScaleFullscreen) {
      return const MagpieProfileWriteResult.skipped(
        MagpieProfileSkipReason.alreadySatisfied,
      );
    }
    // 已有同身份 profile（多半是用户自己在 Magpie 里建的）：**只翻 autoScale 这一个字段**，
    // 其余用户设置一律不动。这就是「增量改写」的全部含义。
    profiles[existing] = <String, dynamic>{
      ..._asStringKeyed(entry),
      'autoScale': kMagpieAutoScaleFullscreen,
    };
    return MagpieProfileWriteResult.applied(<String, dynamic>{
      ...config,
      'profiles': profiles,
    });
  }

  profiles.add(<String, dynamic>{
    'name': profileName.trim(),
    'packaged': false,
    'pathRule': identity.executablePath,
    'classNameRule': identity.windowClassName,
    'launcherPath': '',
    'autoScale': kMagpieAutoScaleFullscreen,
    'launchParameters': '',
    'scalingMode': scalingMode,
  });
  return MagpieProfileWriteResult.applied(<String, dynamic>{
    ...config,
    'profiles': profiles,
  });
}

/// **纯函数**：把某条 profile 的自动缩放关回去（会话结束时的收束）。
///
/// 只认我们那条身份，且只翻 `autoScale`。找不到就返回
/// [MagpieProfileSkipReason.alreadySatisfied] —— 会话收尾绝不因为「配置里没有我们的
/// profile」而报错。
///
/// 为什么必须关回去：留着 `autoScale=Fullscreen` 的 profile，用户下次**不经 Hibiki**直接
/// 双击游戏时也会被 Magpie 的 50ms 前台轮询自动拉起缩放。那是我们没被授权做的事。
MagpieProfileWriteResult magpieConfigWithAutoScaleDisabled({
  required Map<String, dynamic> config,
  required MagpieWindowIdentity identity,
}) {
  final Object? rawProfiles = config['profiles'];
  if (rawProfiles is! List || rawProfiles.isEmpty) {
    return const MagpieProfileWriteResult.skipped(
      MagpieProfileSkipReason.schemaMismatch,
    );
  }
  final List<Object?> profiles = List<Object?>.from(rawProfiles);
  final int existing = _indexOfProfile(profiles, identity);
  if (existing < 0) {
    return const MagpieProfileWriteResult.skipped(
      MagpieProfileSkipReason.alreadySatisfied,
    );
  }
  final Map<Object?, Object?> entry =
      profiles[existing]! as Map<Object?, Object?>;
  if (entry['autoScale'] == kMagpieAutoScaleDisabled) {
    return const MagpieProfileWriteResult.skipped(
      MagpieProfileSkipReason.alreadySatisfied,
    );
  }
  profiles[existing] = <String, dynamic>{
    ..._asStringKeyed(entry),
    'autoScale': kMagpieAutoScaleDisabled,
  };
  return MagpieProfileWriteResult.applied(<String, dynamic>{
    ...config,
    'profiles': profiles,
  });
}

/// **纯函数**：把配置里所有由 Hibiki 建的 profile（名字带 [kMagpieHibikiProfilePrefix]
/// 前缀）的自动缩放一次性关回去。
///
/// 与 [magpieConfigWithAutoScaleDisabled] 的区别只在**认谁**：那个按窗口身份关单条，
/// 用于本次会话的正常收尾；这个按名字前缀批量关，用于**启动期对账** —— 上次进程崩溃、
/// 断电或被任务管理器结束时收尾根本没跑过，配置里会留下一批 `autoScale=Fullscreen`
/// 的孤儿，而那时我们既没有窗口 hwnd 也没有身份可用（那是上个进程的内存）。
///
/// 一条都不用改时返回 [MagpieProfileSkipReason.alreadySatisfied] —— 调用方据此
/// **一个字节都不写**，也就不会无谓地和别的 Magpie 实例抢配置文件。
MagpieProfileWriteResult magpieConfigWithHibikiAutoScaleCleared({
  required Map<String, dynamic> config,
}) {
  final Object? rawProfiles = config['profiles'];
  if (rawProfiles is! List || rawProfiles.isEmpty) {
    return const MagpieProfileWriteResult.skipped(
      MagpieProfileSkipReason.schemaMismatch,
    );
  }
  final List<Object?> profiles = List<Object?>.from(rawProfiles);
  bool changed = false;
  // 从 1 开始：第 0 项是默认 profile，它没有 name，永远不是我们建的。
  for (int i = 1; i < profiles.length; i++) {
    final Object? entry = profiles[i];
    if (entry is! Map) continue;
    final Object? name = entry['name'];
    if (name is! String || !name.startsWith(kMagpieHibikiProfilePrefix)) {
      continue;
    }
    if (entry['autoScale'] == kMagpieAutoScaleDisabled) continue;
    profiles[i] = <String, dynamic>{
      ..._asStringKeyed(entry.cast<Object?, Object?>()),
      'autoScale': kMagpieAutoScaleDisabled,
    };
    changed = true;
  }
  if (!changed) {
    return const MagpieProfileWriteResult.skipped(
      MagpieProfileSkipReason.alreadySatisfied,
    );
  }
  return MagpieProfileWriteResult.applied(<String, dynamic>{
    ...config,
    'profiles': profiles,
  });
}

/// 在 profiles 里找同身份的**非默认** profile 下标；找不到返回 -1。
///
/// 从 1 开始扫：第 0 项是默认 profile，它没有身份字段，永远不该被当成匹配目标。
int _indexOfProfile(List<Object?> profiles, MagpieWindowIdentity identity) {
  for (int i = 1; i < profiles.length; i++) {
    final Object? entry = profiles[i];
    if (entry is! Map) continue;
    if (entry['packaged'] != false) continue;
    if (entry['pathRule'] != identity.executablePath) continue;
    if (entry['classNameRule'] != identity.windowClassName) continue;
    return i;
  }
  return -1;
}

/// `jsonDecode` 出来的嵌套 Map 静态类型是 `Map<String, dynamic>`，但我们从 `List<Object?>`
/// 里取出来时只能断言到 `Map<Object?, Object?>`，展开前需转回字符串键。
Map<String, dynamic> _asStringKeyed(Map<Object?, Object?> source) {
  final Map<String, dynamic> out = <String, dynamic>{};
  source.forEach((Object? key, Object? value) {
    if (key is String) out[key] = value;
  });
  return out;
}
