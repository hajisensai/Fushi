// 反馈 cliIUL82nf：Windows 正式版 DLL 明明随包，番剧详情「配置下载后端」选内置
// 引擎却提示「本次安装缺少内置引擎运行库」。
//
// 根因两层：
// 1. `isEmbeddedTorrentReady` 把「DLL 能否加载」与「下载服务已备好落盘路径」用
//    `&&` 合成一个判据，服务没起时短路、根本不探测 DLL，引导据此报「缺运行库」。
// 2. 下载服务只在启动时（且「浏览」模块开着）起一次，会话中途从「功能模块」打开
//    「浏览」不补跑，路径永远是 null。
//
// 本文件在 AppModel 层锁住：运行库判据独立于服务状态；模块中途打开会走同一入口
// 补起服务；启动入口并发去重、失败不抛且可重试。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

class _RuntimeAppModel extends AppModel {
  _RuntimeAppModel({this.dllLoads = true}) : super(testPlatformServices());

  /// 替身：本次安装的 DLL 能否加载（测试机上没有原生库）。
  final bool dllLoads;

  /// [startAnimeDownloadService] 被调了几次（替身不碰文件系统与计划仓库）。
  int serviceStarts = 0;

  /// 非 null 时下一次启动抛这个错（模拟启动失败）。
  Object? nextStartError;

  /// 非 null 时启动挂在这个 completer 上，直到测试放行（模拟启动还在飞）。
  Completer<void>? gate;

  @override
  bool get supportsEmbeddedTorrent => true;

  @override
  bool probeEmbeddedTorrentRuntime() => dllLoads;

  /// 启动已成功落地（镜像真实实现的 `_animeDownloadService != null` 幂等短路）。
  bool _started = false;

  @override
  Future<void> startAnimeDownloadService() async {
    // 与真实实现一样幂等：模块开关发出的那次启动可能在测试再调入口之前就已落地、
    // 在飞 future 已清空，此时再调必须是 no-op，否则计数取决于 microtask 次序。
    if (_started) return;
    serviceStarts++;
    final Completer<void>? pending = gate;
    if (pending != null) await pending.future;
    final Object? error = nextStartError;
    if (error != null) {
      nextStartError = null;
      Error.throwWithStackTrace(error, StackTrace.current);
    }
    _started = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_torrent_runtime_split_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<_RuntimeAppModel> prefsBacked({required bool browseEnabled}) async {
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    await prefsRepo.setModuleEnabled(ModuleId.browse, browseEnabled);
    return _RuntimeAppModel()
      ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tmp)
      ..wireDatabaseForTesting(db);
  }

  group('运行库判据与下载服务就绪判据分离', () {
    test('下载服务没起（save roots 未设）时运行库仍判为可用', () {
      final _RuntimeAppModel appModel = _RuntimeAppModel();

      expect(appModel.isEmbeddedTorrentHostPrepared, isFalse);
      expect(
        appModel.isEmbeddedTorrentRuntimeAvailable,
        isTrue,
        reason: '服务没起不等于缺运行库：DLL 能加载就该判可用',
      );
      expect(
        appModel.isEmbeddedTorrentReady,
        isFalse,
        reason: '服务没备好路径时懒建入口交不出内置后端，不能判可接任务',
      );
    });

    test('DLL 加载不了时运行库判为不可用', () {
      final _RuntimeAppModel appModel = _RuntimeAppModel(dllLoads: false);

      expect(appModel.isEmbeddedTorrentRuntimeAvailable, isFalse);
      expect(appModel.isEmbeddedTorrentReady, isFalse);
    });
  });

  group('「浏览」模块与下载服务生命周期', () {
    test('会话中途打开「浏览」会补起下载服务', () async {
      final _RuntimeAppModel appModel = await prefsBacked(browseEnabled: false);
      expect(appModel.moduleVisibility.isEnabled(ModuleId.browse), isFalse);

      await appModel.setModuleEnabled(ModuleId.browse, true);
      await appModel.ensureAnimeDownloadServiceRunning();

      expect(
        appModel.serviceStarts,
        1,
        reason: '模块开关必须与启动走同一入口起服务，否则内置引擎一直判未就绪',
      );
    });

    test('关闭「浏览」不起服务；模块关着时入口什么都不做', () async {
      final _RuntimeAppModel appModel = await prefsBacked(browseEnabled: true);

      await appModel.setModuleEnabled(ModuleId.browse, false);
      await appModel.ensureAnimeDownloadServiceRunning();

      expect(appModel.serviceStarts, 0);
    });

    test('启动在飞时并发调用共享同一次启动', () async {
      final _RuntimeAppModel appModel = await prefsBacked(browseEnabled: true);
      final Completer<void> gate = Completer<void>();
      appModel.gate = gate;

      final Future<void> first = appModel.ensureAnimeDownloadServiceRunning();
      final Future<void> second = appModel.ensureAnimeDownloadServiceRunning();
      await appModel.setModuleEnabled(ModuleId.browse, true);
      gate.complete();
      await Future.wait(<Future<void>>[first, second]);

      expect(appModel.serviceStarts, 1);
    });

    test('启动失败不抛给调用方，之后再调用可重试', () async {
      final _RuntimeAppModel appModel = await prefsBacked(browseEnabled: true);
      appModel.nextStartError = StateError('boom');

      await appModel.ensureAnimeDownloadServiceRunning();
      expect(appModel.serviceStarts, 1);

      await appModel.ensureAnimeDownloadServiceRunning();
      expect(
        appModel.serviceStarts,
        2,
        reason: '失败的那次不能把入口永久卡死在一个已完成的 future 上',
      );
    });
  });
}
