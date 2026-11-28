/// 视频规格服务的 Riverpod 接线：交出 AppModel 持有的那一个 [VideoSpecsService]。
///
/// 与服务本体（`video_specs_service.dart`）分开：服务与角标 / 规格面板不读 AppModel；只有这一处
/// 接线读（只有视频库页 import）。服务本体再 import AppModel 就会把它连同角标、规格面板一起拖回
/// lib/ 的 import 大环（`test/build/import_cycle_guard_test.dart`，2026-11-27）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/video/video_specs_service.dart';
import 'package:fushi/src/models/app_model.dart' show appProvider;

/// 取服务实例。生命周期归 `AppModel`（那里懒建、db 关闭时销毁）。
///
/// **必须是普通 [Provider]，不能是 `ChangeNotifierProvider`**：后者会给它返回的
/// notifier 注册 `onDispose(notifier.dispose)`，也就是说 provider 一旦重算，上一次
/// 的返回值就被 dispose。而这里返回的是 AppModel 持有并复用的那一个实例——它会被
/// 就地打死，AppModel 毫不知情、继续把这个死实例发给所有人（`_disposed` 让全部探测
/// 短路，重算时的 `addListener` 还会直接抛断言）。
///
/// 触发条件一点也不罕见：`appProvider` 本身是 `ChangeNotifierProvider<AppModel>`，
/// riverpod 对 ChangeNotifier 恒判 `updateShouldNotify = true`，于是**每一次**
/// `AppModel.notifyListeners()`（写设置、扫描、播放进度…）都会让本 provider 重算。
/// 机制由 `test/media/video/video_specs_provider_lifecycle_test.dart` 钉住。
///
/// 消费方拿到实例后用 `ListenableBuilder` 订阅变化——重建面照样收敛在角标子树，
/// 服务通知频率高（滚一屏几十次），绝不能经 AppModel 的 `notifyListeners` 转发。
final videoSpecsProvider = Provider<VideoSpecsService>(
  (ref) => ref.watch(appProvider).videoSpecsService,
);
