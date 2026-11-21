import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_channel.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi/src/shortcuts/global_external_lookup_route.dart';
import 'package:fushi/src/shortcuts/global_hotkey_backend.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 拍板台 pr3605：app 外热键单独一个总开关（`app_external_hotkeys_enabled`），
/// 不挂在查词页模块上。关着时 OS 热键后端、鼠标侧键 RawInput 监听、手柄触发
/// 入口一个都不装；打开即按当前绑定装上；再关掉全部撤掉。覆盖窗本身不受影响。
///
/// 控制器是进程级单例、`start` 是单向闩，所以本文件只放这一条用例。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('总开关关：启动不装任何 app 外触发源；打开装上；再关全部撤掉', () async {
    GlobalLookupController.platformOverride = true;
    FloatingLyricChannel.platformOverride = false;
    GalHookTextOverlayChannel.platformOverride = false;
    final List<_RecordingBackend> backends = <_RecordingBackend>[];
    GlobalLookupController.hotKeyBackendOverride = () {
      final _RecordingBackend backend = _RecordingBackend();
      backends.add(backend);
      return backend;
    };
    final List<String> overlayCalls = <String>[];
    final List<int> mouseTriggerButtons = <int>[];
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(FushiChannels.globalLookup, (
      MethodCall call,
    ) async {
      overlayCalls.add(call.method);
      if (call.method == 'setGlobalMouseTrigger') {
        final Map<Object?, Object?> args =
            call.arguments as Map<Object?, Object?>;
        mouseTriggerButtons.add(args['button']! as int);
      }
      return null;
    });
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    final Directory storeDir = Directory.systemTemp.createTempSync(
      'fushi_external_triggers_toggle',
    );
    addTearDown(() async {
      GlobalLookupController.platformOverride = null;
      FloatingLyricChannel.platformOverride = null;
      GalHookTextOverlayChannel.platformOverride = null;
      GlobalLookupController.hotKeyBackendOverride = null;
      GlobalExternalLookupRoute.debugClear();
      messenger.setMockMethodCallHandler(FushiChannels.globalLookup, null);
      await db.close();
      if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
    });
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir)
      ..wireDatabaseForTesting(db);
    expect(appModel.appExternalHotkeysEnabled, isTrue, reason: '默认开');
    await appModel.setAppExternalHotkeysEnabled(false);
    appModel.shortcutRegistry.loadDefaults(TargetPlatform.windows);
    // 再给全局查词绑一个鼠标侧键（后退键 = 3），验证 RawInput 那条也受开关管。
    final ShortcutBindingSet defaults = appModel.shortcutRegistry.bindingsFor(
      ShortcutAction.globalExternalLookup,
    );
    appModel.shortcutRegistry.updateBinding(
      ShortcutAction.globalExternalLookup,
      defaults.copyWith(mouseBindings: const <MouseBinding>[MouseBinding(3)]),
    );

    final GlobalLookupController controller = GlobalLookupController.instance;
    await controller.start(appModel: appModel);
    await pumpEventQueue();

    // 覆盖窗照起（galgame 点词 / 系统悬浮球要用），只是不装 app 外触发源。
    expect(controller.isAvailable, isTrue);
    expect(overlayCalls, contains('prepare'));
    expect(backends, isEmpty, reason: '关着：不建热键后端（portal 上是一条会话）');
    expect(controller.hotKeyStatus.value, isNull);
    expect(GlobalExternalLookupRoute.current, isNull, reason: '手柄触发不登记');
    expect(mouseTriggerButtons.where((int b) => b != 0), isEmpty);

    // 关着时改绑定：照样不建后端、不注册侧键。
    appModel.shortcutRegistry.updateBinding(
      ShortcutAction.globalExternalOpenLookupPage,
      const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(
            key: LogicalKeyboardKey.keyK,
            modifiers: <ModifierKey>{ModifierKey.ctrl, ModifierKey.alt},
          ),
        ],
      ),
    );
    await pumpEventQueue();
    expect(backends, isEmpty);
    expect(mouseTriggerButtons.where((int b) => b != 0), isEmpty);

    // 打开：按当前绑定装上三条触发源。
    await appModel.setAppExternalHotkeysEnabled(true);
    await controller.applyAppExternalTriggersEnabled();
    await pumpEventQueue();
    expect(backends, hasLength(1));
    final List<GlobalHotKeyRequest> requests = backends.single.applied.last;
    expect(requests.first.id, ShortcutAction.globalExternalLookup.key);
    expect(requests.first.chord, isNotNull, reason: '默认 Ctrl+Alt+D');
    final GlobalHotKeyRequest openPage = requests.firstWhere(
      (GlobalHotKeyRequest r) =>
          r.id == ShortcutAction.globalExternalOpenLookupPage.key,
    );
    expect(openPage.chord?.keysym, 'k', reason: '关着时改的绑定生效');
    expect(controller.hotKeyStatus.value, backends.single.status);
    expect(GlobalExternalLookupRoute.current, isNotNull);
    expect(mouseTriggerButtons.last, 3);

    // 再关：后端拆掉、状态清空、手柄入口注销、侧键监听撤掉。
    await appModel.setAppExternalHotkeysEnabled(false);
    await controller.applyAppExternalTriggersEnabled();
    await pumpEventQueue();
    expect(backends.single.disposed, isTrue);
    expect(controller.hotKeyStatus.value, isNull);
    expect(GlobalExternalLookupRoute.current, isNull);
    expect(mouseTriggerButtons.last, 0);

    // 关着时注册表变更不会重建后端。
    appModel.shortcutRegistry.updateBinding(
      ShortcutAction.globalExternalOpenLookupPage,
      const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(
            key: LogicalKeyboardKey.keyJ,
            modifiers: <ModifierKey>{ModifierKey.ctrl, ModifierKey.alt},
          ),
        ],
      ),
    );
    await pumpEventQueue();
    expect(backends, hasLength(1));
  });
}

class _RecordingBackend implements GlobalHotKeyBackend {
  final List<List<GlobalHotKeyRequest>> applied = <List<GlobalHotKeyRequest>>[];
  final StreamController<GlobalHotKeyStatus> _changes =
      StreamController<GlobalHotKeyStatus>.broadcast();
  bool disposed = false;

  @override
  GlobalHotKeyBackendKind get kind => GlobalHotKeyBackendKind.native;

  @override
  GlobalHotKeyStatus get status =>
      const GlobalHotKeyStatus.idle(GlobalHotKeyBackendKind.native);

  @override
  Stream<GlobalHotKeyStatus> get statusChanges => _changes.stream;

  @override
  Future<void> apply(List<GlobalHotKeyRequest> requests) async {
    applied.add(requests);
  }

  @override
  Future<void> rebind() async {}

  @override
  Future<bool> configure({String? activationToken}) async => false;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _changes.close();
  }
}
