import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/shortcuts/global_hotkey_backend.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// Linux Wayland: the app-outside hotkeys no longer hang off the lookup card
/// overlay. A Wayland session has no overlay (the card places its own window),
/// yet [GlobalLookupController.start] must still register the hotkeys — through
/// whatever [GlobalHotKeyBackend] the platform uses (the GlobalShortcuts portal
/// there) — and the actions must reach their executors.
///
/// The controller is a process singleton with a one-way `start` latch, so this
/// file holds one scenario.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('activation token is scoped to one activation, across awaits', () async {
    expect(DesktopLookupService.activationTokenInScope, isNull);
    String? seen;
    await DesktopLookupService.runWithActivationToken<void>('tok', () async {
      await Future<void>.delayed(Duration.zero);
      seen = DesktopLookupService.activationTokenInScope;
    });
    expect(seen, 'tok');
    expect(DesktopLookupService.activationTokenInScope, isNull);
    await DesktopLookupService.runWithActivationToken<void>(null, () async {
      seen = DesktopLookupService.activationTokenInScope;
    });
    expect(seen, isNull);
  });

  test('no overlay: start still registers the hotkeys through the backend; '
      'screen OCR (needs the overlay) is left out; activations dispatch; a '
      'remap re-applies; release disposes the backend', () async {
    // No lookup card overlay, as on a Wayland session.
    GlobalLookupController.platformOverride = false;
    final _RecordingBackend backend = _RecordingBackend();
    GlobalLookupController.hotKeyBackendOverride = () => backend;
    final List<String> overlayCalls = <String>[];
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(FushiChannels.globalLookup, (
      MethodCall call,
    ) async {
      overlayCalls.add(call.method);
      return null;
    });
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    final Directory storeDir = Directory.systemTemp.createTempSync(
      'fushi_hotkey_wiring',
    );
    addTearDown(() async {
      GlobalLookupController.platformOverride = null;
      GlobalLookupController.hotKeyBackendOverride = null;
      messenger.setMockMethodCallHandler(FushiChannels.globalLookup, null);
      await db.close();
      if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
    });
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir)
      ..wireDatabaseForTesting(db);
    await prefs.setModuleEnabled(ModuleId.lookup, true);
    appModel.shortcutRegistry.loadDefaults(TargetPlatform.windows);

    final GlobalLookupController controller = GlobalLookupController.instance;
    await controller.followLookupModule(appModel);

    expect(controller.isAvailable, isFalse, reason: 'no overlay here');
    expect(overlayCalls, isEmpty, reason: 'no overlay channel traffic');
    expect(backend.applied, hasLength(1));
    final List<GlobalHotKeyRequest> requests = backend.applied.single;
    expect(requests.map((GlobalHotKeyRequest r) => r.id), <String>[
      ShortcutAction.globalExternalLookup.key,
      ShortcutAction.globalExternalOpenLookupPage.key,
    ]);
    for (final GlobalHotKeyRequest r in requests) {
      expect(r.description, isNotEmpty, reason: 'the desktop shows it');
    }
    // Default Ctrl+Alt+D → physical D, keysym "d" for the portal hint.
    expect(requests.first.chord, isNotNull);
    expect(requests.first.chord!.keysym, 'd');
    expect(
      requests.first.chord!.physicalUsage,
      PhysicalKeyboardKey.keyD.usbHidUsage,
    );
    expect(controller.hotKeyStatus.value, backend.status);

    // Backend status flows to the settings page.
    backend.emit(
      const GlobalHotKeyStatus(
        kind: GlobalHotKeyBackendKind.portal,
        problem: GlobalHotKeyProblem.dialogCancelled,
      ),
    );
    await pumpEventQueue();
    expect(
      controller.hotKeyStatus.value?.problem,
      GlobalHotKeyProblem.dialogCancelled,
    );

    // "Open lookup page" activation reaches its executor.
    final int seq = appModel.homeDictionaryTabRequest.value.seq;
    await requests[1].onActivated(
      const GlobalHotKeyActivation(activationToken: 'xdg-token'),
    );
    expect(appModel.homeDictionaryTabRequest.value.seq, seq + 1);
    expect(appModel.homeDictionaryTabRequest.value.focusSearch, isTrue);

    // A remap re-applies the whole set.
    final FushiShortcutRegistry registry = appModel.shortcutRegistry;
    registry.updateBinding(
      ShortcutAction.globalExternalOpenLookupPage,
      ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(
            key: LogicalKeyboardKey.keyK,
            modifiers: const <ModifierKey>{ModifierKey.ctrl, ModifierKey.alt},
          ),
        ],
      ),
    );
    await pumpEventQueue();
    expect(backend.applied.length, greaterThanOrEqualTo(2));
    expect(backend.applied.last[1].chord?.keysym, 'k');

    // Settings actions go to the backend.
    await controller.rebindHotKeys();
    expect(backend.rebinds, 1);
    expect(await controller.configureHotKeysInSystem(), isTrue);

    await controller.releaseHotKeys();
    expect(backend.disposed, isTrue);
  });
}

class _RecordingBackend implements GlobalHotKeyBackend {
  final List<List<GlobalHotKeyRequest>> applied = <List<GlobalHotKeyRequest>>[];
  final StreamController<GlobalHotKeyStatus> _changes =
      StreamController<GlobalHotKeyStatus>.broadcast();
  GlobalHotKeyStatus _status = const GlobalHotKeyStatus.idle(
    GlobalHotKeyBackendKind.portal,
  );
  int rebinds = 0;
  bool disposed = false;

  void emit(GlobalHotKeyStatus next) {
    _status = next;
    _changes.add(next);
  }

  @override
  GlobalHotKeyBackendKind get kind => GlobalHotKeyBackendKind.portal;

  @override
  GlobalHotKeyStatus get status => _status;

  @override
  Stream<GlobalHotKeyStatus> get statusChanges => _changes.stream;

  @override
  Future<void> apply(List<GlobalHotKeyRequest> requests) async {
    applied.add(requests);
  }

  @override
  Future<void> rebind() async => rebinds++;

  @override
  Future<bool> configure({String? activationToken}) async => true;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _changes.close();
  }
}
