import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

// BUG-1797：「已制卡」标记必须能被 Anki 的真实状态推翻——用户在 Anki 里删掉那张卡
// 之后，标记要消失。复核入口是 BaseAnkiRepository.findDeletedNotes。
//
// 这组测试守的是它**返回值口径**，那才是要害：只报「后端明确应答、且应答里没有这张
// note」的 id。查询失败 / AnkiConnect 不可达一律空集——把「问不到」当成「已删除」会在
// Anki 没开着的时候把满屏徽章全部清空，比不复核更糟。

/// 按 id 供应 notesInfo 应答的 service double；[failure] 非空时一律抛出，
/// 模拟 AnkiConnect 不可达 / 业务错误。
class _NotesService extends AnkiConnectService {
  _NotesService({this.present = const <int>{}, this.failure});

  /// Anki 中仍然存在的 note id。
  final Set<int> present;
  final Object? failure;

  final List<List<int>> queries = <List<int>>[];

  @override
  Future<Map<int, Map<String, String>>> notesInfoMany(List<int> noteIds) async {
    queries.add(List<int>.from(noteIds));
    final Object? boom = failure;
    if (boom != null) throw boom;
    // 真 AnkiConnect 对不存在的 note 回的是**空对象项**，notesInfoMany 那边已把它
    // 跳过——所以「id 不在返回 map 里」精确等于「Anki 说这张 note 没了」。
    return <int, Map<String, String>>{
      for (final int id in noteIds)
        if (present.contains(id)) id: <String, String>{'Expression': '語'},
    };
  }
}

class _Repo extends AnkiConnectRepository {
  _Repo({required AnkiConnectService service}) : super(service: service);

  @override
  Future<AnkiSettings> loadSettings() async => const AnkiSettings(
        selectedDeckId: 1,
        selectedNoteTypeId: 2,
        availableDecks: <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
        availableNoteTypes: <AnkiNoteType>[
          AnkiNoteType(
            id: 2,
            name: 'Fushi',
            fields: <String>['Expression', 'Reading'],
          ),
        ],
      );
}

void main() {
  group('BUG-1797 findDeletedNotes 只报「确认已删除」', () {
    test('Anki 应答里缺席的 note 被判为已删除', () async {
      final service = _NotesService(present: <int>{11, 33});
      final Set<int> deleted =
          await _Repo(service: service).findDeletedNotes(<int>{11, 22, 33});
      expect(deleted, <int>{22},
          reason: '只有 22 不在应答里，它才是被用户删掉的那张');
    });

    test('全部都还在时返回空集（一个徽章都不该清）', () async {
      final service = _NotesService(present: <int>{11, 22});
      final Set<int> deleted =
          await _Repo(service: service).findDeletedNotes(<int>{11, 22});
      expect(deleted, isEmpty);
    });

    test('一次批量往返查完，不是每个 id 一次', () async {
      final service = _NotesService(present: <int>{1, 2, 3});
      await _Repo(service: service).findDeletedNotes(<int>{3, 1, 2});
      expect(service.queries.length, 1, reason: '常数 1 次往返，不随 id 数增长');
      expect(service.queries.single, <int>[1, 2, 3], reason: '排序后送出，便于复现');
    });

    test('空输入不打网络', () async {
      final service = _NotesService();
      final Set<int> deleted =
          await _Repo(service: service).findDeletedNotes(<int>{});
      expect(deleted, isEmpty);
      expect(service.queries, isEmpty);
    });

    // ── 本组的核心不变式 ────────────────────────────────────────────────
    test('AnkiConnect 不可达时返回空集，绝不把「问不到」当成「已删除」', () async {
      final service = _NotesService(
        present: <int>{},
        failure: const SocketExceptionStub(),
      );
      final Set<int> deleted =
          await _Repo(service: service).findDeletedNotes(<int>{11, 22});
      expect(deleted, isEmpty,
          reason: 'Anki 没开着时必须一张都不清，否则满屏徽章会被误清空');
    });

    test('业务错误（牌组/字段异常）同样返回空集', () async {
      final service = _NotesService(
        failure: StateError('AnkiConnect: model not found'),
      );
      final Set<int> deleted =
          await _Repo(service: service).findDeletedNotes(<int>{7});
      expect(deleted, isEmpty);
    });
  });

  group('BUG-1797 基类默认降级', () {
    test('拿不到 note 存在性的后端恒返回空集（保持旧 latch 行为）', () async {
      expect(await _DegradedRepo().findDeletedNotes(<int>{1, 2}), isEmpty);
    });
  });
}

/// 只实现抽象成员的最小后端，用来验证基类默认实现（AnkiDroid / AnkiMobile 走这条）。
class _DegradedRepo extends BaseAnkiRepository {
  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      throw UnimplementedError();

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      const MineOutcome(MineResult.error);

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}

/// 独立的传输层异常桩：不引 dart:io，避免测试对平台 socket 类型的耦合。
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();

  @override
  String toString() => 'SocketException: Connection refused';
}
