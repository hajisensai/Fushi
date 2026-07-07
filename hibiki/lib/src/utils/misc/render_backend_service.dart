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

  /// 可注入的 channel（测试替换成 mock messenger）；生产走真实 native channel。
  @visibleForTesting
  MethodChannel channel = HibikiChannels.render;

  bool _impellerDisabled = false;

  /// 当前**已持久化**的「关闭 Impeller」意图（同步读，供设置开关渲染）。
  /// 它反映的是**下次启动**会不会关 Impeller，而非本次运行的实际后端——本次运行
  /// 的渲染后端在引擎启动那一刻就定死，无法中途改变。
  bool get impellerDisabled => _impellerDisabled;

  bool _supported = false;

  /// 是否成功从 native 读到过状态（false = 非 Android / channel 未接线，设置项据此隐藏）。
  bool get isSupported => _supported;

  /// 启动时读一次 native 持久化值进缓存。非 Android / channel 未接线时保持默认
  /// false 且 [isSupported] 为 false。幂等：可安全重复调用。
  Future<void> init() async {
    try {
      final bool? value =
          await channel.invokeMethod<bool>('isImpellerDisabled');
      _impellerDisabled = value ?? false;
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
}
