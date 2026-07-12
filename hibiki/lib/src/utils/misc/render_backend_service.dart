import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

/// TODO-1232 A3：渲染后端（Impeller vs Skia）实验开关的 Dart 侧门面。
///
/// 背景：realme 8（Mali-G76 / Android 11）上视频「能播但恒黑」——mpv 侧解码 /
/// 纹理握手 / `vo=gpu` 全绿（见 `[VIDEO-DIAG]` 诊断日志），疑为 Flutter Impeller
/// 在该 ROM 上合成 media_kit 外部纹理（SurfaceTexture）静默失败。本开关让用户免
/// adb、免重新出包即可切到 Skia 渲染后端自证：若关掉 Impeller 后画面正常＝坐实
/// Impeller/Mali 合成层，据此根治（如换纹理路径），而非继续在 mpv 侧空转。
///
/// 机制：Impeller 是**引擎初始化期**从 AndroidManifest meta-data 或命令行 shell
/// arg 读取的决定，Dart 运行时无法直接翻转它。因此本开关只把用户意图**持久化到
/// native**（[HibikiChannels.render] → `MainActivity` 写自有 SharedPreferences
/// 文件）；`MainActivity` 在**下次启动**的 `getFlutterShellArgs` 里读它，命中则
/// 追加 `--enable-impeller=false`（命令行值优先于 manifest 默认）。所以语义天然
/// 是「重启后生效」。仅 Android 接线，其它平台 channel 缺失，读写静默降级。
class RenderBackendService {
  RenderBackendService._();

  /// 单例：native channel 进程级，一个实例即可覆盖全 app。
  static final RenderBackendService instance = RenderBackendService._();

  /// TODO-1232：把 native 持久化的「关闭 Impeller」意图（三态：`null`＝用户从未在
  /// 设置里动过开关 / `true`＝显式选 Skia / `false`＝显式选 Impeller）解析成本平台
  /// **实际生效**的「关闭 Impeller（走 Skia）」决定。显式设置 > 平台默认：
  ///   * [storedPref] != null：用户显式设过 —— 直接遵从其选择，无视平台默认。
  ///   * [storedPref] == null：用户从未设置 —— 回落到平台默认 `false`（保持引擎默认
  ///     Impeller），**所有平台一致**（Android 亦然）：
  ///       - Impeller 是 Flutter 现默认，多数机型渲染更顺、无 Skia 首帧 shader 卡顿；
  ///         为它保住这份收益，Android 不再全局默认翻到 Skia。
  ///       - 少数 Android GPU（如 Mali-G76 / Android 11，见 BUG-597）上 Impeller 静默
  ///         不合成 media_kit 外部视频纹理（SurfaceProducer），解码/纹理握手全绿仍黑屏。
  ///         这些机型改由**播放器设置面板里可发现的一键「切 Skia 并重启」入口**降级
  ///         （见 video_quick_settings_sheet 的渲染降级行 + [setImpellerDisabled]），
  ///         而非拿全体用户的性能换少数机型的兼容。
  ///
  /// 纯函数、无副作用，便于离屏单测。与 native 权威决策同源：
  /// `MainActivity.getFlutterShellArgs` 在引擎启动那一刻用等价逻辑（未设置→保持
  /// Impeller）决定是否追加 `--enable-impeller=false`；本函数是 Dart 侧镜像，供
  /// 设置开关显示与诊断标签（守卫见 render_backend_service_test /
  /// impeller_default_guard_test 锁两侧同默认）。[isAndroid] 保留在签名里以对齐 native
  /// 决策点形状、便于将来再按平台分默认，当前所有平台默认同为 Impeller。
  static bool resolveImpellerDisabled({
    required bool? storedPref,
    required bool isAndroid,
  }) =>
      storedPref ?? false;

  /// 可注入的 channel（测试替换成 mock messenger）；生产走真实 native channel。
  @visibleForTesting
  MethodChannel channel = HibikiChannels.render;

  bool _impellerDisabled = false;

  /// 当前**已持久化**的「关闭 Impeller」意图（同步读，供设置开关渲染）。
  /// 它反映的是**下次启动**会不会关 Impeller，而非本次运行的实际后端——本次运行
  /// 的渲染后端在引擎启动那一刻就定死，无法中途改变。
  bool get impellerDisabled => _impellerDisabled;

  /// 本次运行**实际生效**的「已关 Impeller」态：`true`＝本次启动确实关掉了 Impeller
  /// （跑 Skia）。与 [impellerDisabled]（下次启动意图，可被用户在设置里翻）分离——
  /// `MainActivity.getFlutterShellArgs` 在引擎启动那一刻读同一个 native pref 决定是否
  /// 追加 `--enable-impeller=false`，而 [init] 首次读到的就是那一刻的值（此时首帧未出、
  /// 无 UI，pref 不可能被改），故它精确反映本运行实际后端。用户在设置里翻开关只改
  /// [impellerDisabled]（下次启动），本快照不动——诊断日志据此**不会把「已翻但未重启」
  /// 误报成 Skia**。仅首次 [init] 取快照。
  bool _activeImpellerDisabled = false;
  bool _activeSnapshotTaken = false;

  /// 本次运行实际生效的渲染后端（供 `[VIDEO-DIAG]` 诊断头自证测的是哪个后端）。
  bool get activeImpellerDisabled => _activeImpellerDisabled;

  /// 诊断日志用的后端标签：`n/a`（非 Android / channel 未接线，此开关不适用）、
  /// `skia`（本次运行已关 Impeller）、`impeller`（本次运行跑 Impeller）。让用户导出的
  /// `[VIDEO-DIAG]` 日志能**无歧义**自证「测的是 Skia 还是 Impeller」——是 realme 8
  /// 「纹理握手全绿仍黑屏」定 Impeller 合成层根因、以及关 Impeller 后复测是否解决的判据。
  String get activeBackendLabel =>
      !_supported ? 'n/a' : (_activeImpellerDisabled ? 'skia' : 'impeller');

  bool _supported = false;

  /// 是否成功从 native 读到过状态（false = 非 Android / channel 未接线，设置项据此隐藏）。
  bool get isSupported => _supported;

  /// 启动时读一次 native 持久化值进缓存。非 Android / channel 未接线时保持默认
  /// false 且 [isSupported] 为 false。幂等：可安全重复调用。
  Future<void> init() async {
    try {
      // native 返回三态：`null`＝用户从未设置该开关（按平台默认，Android 关 Impeller
      // 走 Skia）；非 null＝用户显式设过，遵从其选择。channel 有响应即代表本平台已
      // 接线（当前仅 Android），用 Platform.isAndroid（物理 OS，不受主题 target 平台
      // 覆盖影响）兜底未设置态，与 native getFlutterShellArgs 的同默认保持一致。
      final bool? storedPref =
          await channel.invokeMethod<bool>('isImpellerDisabled');
      _impellerDisabled = resolveImpellerDisabled(
        storedPref: storedPref,
        isAndroid: Platform.isAndroid,
      );
      // 首次 init 取「本次运行实际后端」快照：此刻（首帧前、无 UI）读到的 pref 即
      // 引擎启动那一刻 getFlutterShellArgs 读到的同一个值，故精确反映本运行后端。
      // 之后用户翻开关只改 _impellerDisabled（下次启动意图），本快照不动。
      if (!_activeSnapshotTaken) {
        _activeImpellerDisabled = _impellerDisabled;
        _activeSnapshotTaken = true;
      }
      _supported = true;
    } on MissingPluginException {
      _supported = false;
    } on PlatformException {
      _supported = false;
    }
  }

  /// 持久化「关闭 Impeller」意图到 native（重启后由 `getFlutterShellArgs` 应用）。
  /// 返回 true=已写入（Android），false=当前平台不支持（静默降级）。
  Future<bool> setImpellerDisabled(bool value) async {
    try {
      await channel.invokeMethod<void>('setImpellerDisabled', value);
      _impellerDisabled = value;
      _supported = true;
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 测试隔离用：清掉缓存与「本次运行后端」快照，让每个用例从确定初态起跑
  /// （单例 [instance] 跨用例复用，否则首个用例的快照会渗到后续用例）。
  @visibleForTesting
  void debugResetForTesting() {
    _impellerDisabled = false;
    _activeImpellerDisabled = false;
    _activeSnapshotTaken = false;
    _supported = false;
  }
}
