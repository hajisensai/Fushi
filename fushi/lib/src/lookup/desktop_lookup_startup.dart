import 'dart:async';

import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/mining/cross_app_audio/cross_app_audio_capture.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 桌面启动链里的两块查词宿主：全局查词覆盖窗（查词卡 surface + app 外热键）与
/// galgame 台词浮窗。首帧后由 `main.dart` 调用一次。
///
/// **全局查词覆盖窗不看「查词」模块**：[ModuleId.lookup] 只关查词页入口、查词能力
/// 全留（用户拍板，见 `module_registry.dart` 的 `moduleOfSettingsDestination`）。
/// 覆盖窗是查词卡这块共享基础设施，消费者横跨多个模块——galgame 游戏内查词
/// （games）、桌面应用外悬浮球的应用外查词 / 截屏识字、app 外取词热键（含有声书
/// 全局热键）——所以它是否启动只由平台能力决定，判据只在
/// [GlobalLookupController.start] 里写一次（`isSupported` / `osHotKeysSupported`），
/// 这里不再叠模块门。此前按查词模块门控，查词页一关，galgame 点词与应用外球的
/// 查词按钮就全部失效（BUG-4846）。
///
/// galgame 台词浮窗属于 games 模块，照旧随模块；两者正交，写成两条独立语句。
///
/// 电脑端「缓存其他应用的声音」（拍板 design-cross-app-audio-desktop）开着时在这里恢复
/// 常驻录环：它的唯一消费者就是覆盖窗的应用外查词制卡。
Future<void> startDesktopLookupSurfaces(AppModel appModel) async {
  await GlobalLookupController.instance.start(appModel: appModel);
  unawaited(restoreDesktopCrossAppAudio(appModel));
  if (appModel.moduleVisibility.isEnabled(ModuleId.games) &&
      GalHookTextOverlayController.isSupported) {
    await GalHookTextOverlayController.instance.start(appModel: appModel);
  }
}

/// 电脑端跨应用语音缓存：偏好开着就起常驻录环（与 galgame 会话共用系统混音那一路
/// loopback，各持一张租约）。起不来（没有输出设备等）只记日志，开关照旧开着，下次启动
/// 再试——设置页开关显示的是此刻在不在录。
Future<void> restoreDesktopCrossAppAudio(AppModel appModel) async {
  final CrossAppAudioCapture capture = CrossAppAudioCapture.instance;
  if (!capture.isDesktop || !appModel.prefsRepo.crossAppAudioCaptureDesktop) {
    return;
  }
  final CrossAppAudioStartResult result = await capture.start();
  if (!result.running) {
    ErrorLogService.instance.log(
      'CrossAppAudio.restoreDesktop',
      'loopback start failed: ${result.error}',
    );
  }
}
