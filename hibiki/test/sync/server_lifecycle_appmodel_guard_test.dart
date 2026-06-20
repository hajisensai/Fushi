import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_server_controller.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'sync_settings_schema_source_corpus.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

/// BUG-085: the Hibiki LAN sync server must be owned app-wide by AppModel, not
/// by the sync-settings page widget — leaving the page must not kill the host.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HibikiSyncServerController behavior', () {
    test('startIfEnabled does not bind when hosting is disabled', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      // A fresh DB has hosting disabled → the controller must short-circuit
      // BEFORE constructing the server, so the (throwing) lookup factory proves
      // it never tried to bind.
      final HibikiSyncServerController controller = HibikiSyncServerController(
        navigatorKey: GlobalKey<NavigatorState>(),
        database: () => db,
        syncDataDir: () => Directory.systemTemp.path,
        remoteLookupServiceFactory: () =>
            throw StateError('must not build the server while disabled'),
      );

      expect(controller.isRunning, isFalse);
      expect(controller.boundPort, isNull);

      final HibikiServerStartOutcome outcome =
          await controller.startIfEnabled();

      expect(outcome, isA<HibikiServerStarted>());
      expect(controller.isRunning, isFalse,
          reason: 'disabled hosting must never bind a socket');
    });
  });

  group('source guards: controller wires library service (Task-6)', () {
    test('controller forwards libraryService into HibikiSyncServer', () {
      final String src =
          File('lib/src/sync/hibiki_server_controller.dart').readAsStringSync();
      expect(src.contains('libraryService:'), isTrue,
          reason: 'controller 必须把库服务注入 server，否则 host 端点恒 404');
    });

    test('AppModel wires AppModelLibraryHostService into the controller', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(src.contains('AppModelLibraryHostService'), isTrue,
          reason: 'AppModel 必须构造并注入 AppModelLibraryHostService');
      expect(src.contains('libraryServiceFactory'), isTrue,
          reason: 'AppModel 必须把 libraryServiceFactory 传给 controller');
    });

    test('AppModel passes target language into video sidecar matcher', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      final int factory = src.indexOf('libraryServiceFactory: () => '
          'AppModelLibraryHostService(');
      expect(factory, greaterThanOrEqualTo(0));
      final int removeLocalAudio =
          src.indexOf('removeLocalAudioEntry:', factory);
      expect(removeLocalAudio, greaterThan(factory));
      final int languageArg = src.indexOf(
        'videoSubtitleLangCode: targetLanguage.languageCode',
        factory,
      );
      expect(languageArg, greaterThan(factory),
          reason: '生产 host service 不能落回构造器默认 ja');
      expect(languageArg, lessThan(removeLocalAudio),
          reason: 'sidecar 语言匹配应使用当前学习语言偏好');
    });

    test(
        '_propagateDictionaryDeleteToRemote routes live backend via '
        'backend.deleteRemoteDictionary', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(src.contains('backend.deleteRemoteDictionary'), isTrue,
          reason: '删除传播必须对 HibikiClientSyncBackend 调 live DELETE 端点');
      expect(src.contains('backend is HibikiClientSyncBackend'), isTrue,
          reason: '必须有 is HibikiClientSyncBackend 分流判定');
    });
  });

  group('source guards: AppModel wires audio params into host service (T3.4)',
      () {
    test('AppModel 传 localAudioEntries: 到 AppModelLibraryHostService', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(src.contains('localAudioEntries:'), isTrue,
          reason:
              'AppModel 必须把 localAudioEntries 传给 AppModelLibraryHostService');
    });

    test('AppModel 传 audioDatabaseRoot: 到 AppModelLibraryHostService', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(src.contains('audioDatabaseRoot:'), isTrue,
          reason:
              'AppModel 必须把 audioDatabaseRoot 传给 AppModelLibraryHostService');
    });

    test('AppModel 传 onLocalAudioImported: 到 AppModelLibraryHostService', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(src.contains('onLocalAudioImported:'), isTrue,
          reason:
              'AppModel 必须把 onLocalAudioImported 传给 AppModelLibraryHostService');
    });

    test('AppModel 传 removeLocalAudioEntry: 到 AppModelLibraryHostService', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(src.contains('removeLocalAudioEntry:'), isTrue,
          reason:
              'AppModel 必须传 removeLocalAudioEntry 使 host deleteLocalAudio 真正生效');
    });

    test(
        'orchestrator run() 互联分支调用 _syncLocalAudioLive 而非 syncLocalAudioPackages',
        () {
      final String src =
          File('lib/src/sync/sync_orchestrator.dart').readAsStringSync();
      expect(src.contains('_syncLocalAudioLive('), isTrue,
          reason: 'orchestrator 必须有 _syncLocalAudioLive live 分流方法');
      expect(src.contains('_syncAudiobooksLive('), isTrue,
          reason: 'orchestrator 必须有 _syncAudiobooksLive live 分流方法');
      // run() 里互联分支必须分流到 live 方法
      expect(src.contains('if (syncLocalAudio) await _syncLocalAudioLive('),
          isTrue,
          reason: '互联分支必须调用 _syncLocalAudioLive');
      expect(src.contains('if (syncAudioBookFiles) await _syncAudiobooksLive('),
          isTrue,
          reason: '互联分支必须调用 _syncAudiobooksLive');
    });
  });

  group('source guards: server lifecycle owned by AppModel (BUG-085)', () {
    test('the sync-settings page no longer owns or stops the server', () {
      // TODO-585: schema 拆成主库 + 5 个 part；读合并语料，让 server-ownership
      // 的负向（isNot）守卫覆盖全部 part——否则把 _server?.stop() 塞进某个 part
      // 就能绕过守卫；正向 appModel.syncServerController 现住 interconnect.part.dart。
      final String schema = readSyncSettingsSchemaSource();
      // Ownership moved out of the widget: it must not declare its own server /
      // broadcast fields, nor stop them (its dispose used to kill the host).
      expect(schema, isNot(contains('HibikiSyncServer? _server')),
          reason: 'the settings widget must not own the server instance');
      expect(schema, isNot(contains('_server?.stop()')),
          reason: 'leaving the settings page must not stop the host');
      expect(schema, isNot(contains('_broadcast?.stop()')),
          reason: 'leaving the settings page must not stop LAN broadcast');
      // It now drives the app-level controller instead.
      expect(schema, contains('appModel.syncServerController'),
          reason: 'the widget must delegate to the app-level controller');
    });

    test('AppModel owns the controller and starts it on launch', () {
      final String appModel =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(
          appModel, contains('HibikiSyncServerController syncServerController'),
          reason: 'AppModel must own the server controller for the session');
      expect(appModel, contains('syncServerController.startIfEnabled()'),
          reason: 'the host must start app-wide on launch when enabled');
    });

    test('controller stop only persists disabled when explicitly asked', () {
      final String controller =
          File('lib/src/sync/hibiki_server_controller.dart').readAsStringSync();
      // An app-exit/transient stop must leave serverEnabled untouched so the
      // next launch restores hosting; only a user toggle-off persists disabled.
      expect(controller, contains('stop({bool persistDisabled = false})'),
          reason: 'stop must default to NOT clearing the enabled flag');
      expect(controller,
          contains('if (persistDisabled) await _repo.setServerEnabled(false)'),
          reason:
              'enabled flag is only cleared on an explicit user toggle-off');
    });
  });
}
