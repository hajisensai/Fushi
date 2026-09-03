/// BUG-1681：媒体存储优化区的门控必须是「此刻真能不能用」，不是后端类型。
///
/// `AnkiConnectRepository.supportsMediaMaintenance` 恒 true——它说的是「这个
/// 后端**类型**实现了去重」。但去重要本机直读 collection.media：手机连局域网
/// 里的桌面 Anki 时后端类型也是 AnkiConnect，`getMediaDirPath` 返回的却是那台
/// 机器的路径，本机根本不存在。于是设置页显示一个点了只会说「不可用」的区块。
///
/// 修法是加一层真实探测（[BaseAnkiRepository.probeMediaMaintenance]），并让
/// 「后端不可达」保持**未知**而不是被记成「不支持」——否则桌面用户只要在 Anki
/// 没开的时候进过一次设置页，整区就消失了。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_anki/fushi_anki.dart';

class _ProbeRepo extends BaseAnkiRepository {
  _ProbeRepo({
    required this.staticSupport,
    this.probeResult,
    this.probeThrows = false,
  });

  /// 后端**类型**是否实现了去重（= 旧门控用的那个值）。
  final bool staticSupport;

  /// 探测结论。
  final bool? probeResult;

  /// 探测时后端不可达。
  final bool probeThrows;

  int probeCalls = 0;

  @override
  bool get supportsMediaMaintenance => staticSupport;

  @override
  Future<bool> probeMediaMaintenance() async {
    probeCalls++;
    if (probeThrows) throw const SocketException('host unreachable');
    return probeResult ?? staticSupport;
  }

  @override
  Future<AnkiSettings> loadSettings() async => const AnkiSettings();

  @override
  Future<void> saveSettings(AnkiSettings s) async {}

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      MineOutcome.failure('unused');

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => true;

  @override
  Future<bool> createDeck(String name) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BaseAnkiRepository.probeMediaMaintenance 默认契约', () {
    test('默认实现 = 静态能力，不做任何 I/O', () async {
      final _ProbeRepo off = _ProbeRepo(staticSupport: false);
      expect(await off.probeMediaMaintenance(), isFalse);
    });

    test('默认支持进度与取消（本进程内跑的后端）', () {
      expect(
        _ProbeRepo(staticSupport: true).supportsMediaMaintenanceProgress,
        isTrue,
      );
    });
  });

  group('AnkiViewModel 的探测结论', () {
    test('后端类型就不支持：直接记 false，连探测都不发起', () async {
      final _ProbeRepo repo = _ProbeRepo(staticSupport: false);
      final AnkiViewModel vm = AnkiViewModel(repo);
      await vm.probeMediaMaintenance();
      expect(vm.debugState.mediaMaintenanceAvailable, isFalse);
      expect(repo.probeCalls, 0);
    });

    test('后端类型支持但媒体目录本机没有（手机连局域网桌面）：记 false', () async {
      final _ProbeRepo repo =
          _ProbeRepo(staticSupport: true, probeResult: false);
      final AnkiViewModel vm = AnkiViewModel(repo);
      await vm.probeMediaMaintenance();
      expect(vm.debugState.mediaMaintenanceAvailable, isFalse);
      expect(repo.probeCalls, 1);
    });

    test('本机可读：记 true', () async {
      final _ProbeRepo repo =
          _ProbeRepo(staticSupport: true, probeResult: true);
      final AnkiViewModel vm = AnkiViewModel(repo);
      await vm.probeMediaMaintenance();
      expect(vm.debugState.mediaMaintenanceAvailable, isTrue);
    });

    test('后端不可达（Anki 没开）：保持未知，绝不记成不支持', () async {
      final _ProbeRepo repo =
          _ProbeRepo(staticSupport: true, probeThrows: true);
      final AnkiViewModel vm = AnkiViewModel(repo);
      await vm.probeMediaMaintenance();
      // null = 未知；设置页据此回落静态能力，区块照常显示（点了会报连接错误）。
      expect(vm.debugState.mediaMaintenanceAvailable, isNull);
    });
  });

  group('设置页门控（源码扫描守卫）', () {
    test('媒体存储优化区读探测结论，未知时才回落静态能力', () {
      final String page = File(
        'lib/src/pages/implementations/anki_settings_page.dart',
      ).readAsStringSync();
      // 断言的字面量：`uiState.mediaMaintenanceAvailable ?? vm.supportsMediaMaintenance`
      // 退回裸 `if (vm.supportsMediaMaintenance)` 就是本 bug 的原状。
      expect(
        page,
        contains('uiState.mediaMaintenanceAvailable ?? '
            'vm.supportsMediaMaintenance'),
      );
      expect(page, contains('probeMediaMaintenance()'));
    });
  });
}
