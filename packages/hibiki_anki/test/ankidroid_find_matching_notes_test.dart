import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

// TODO-1007/1008：AnkiDroid 后端「按内容反查全部同词卡 note id + 一行预览」契约。
//
// host 无真 AnkiDroid，故 mock 平台通道 `app.hibiki.reader/anki`，断言：
//  - findMatchingNotes 经 native `findNotesByContent` 传入 models/key/reading/
//    readingFieldIndices，把 native 返回的 [{noteId, preview}, ...] 解析成
//    List<MinedNoteRef>，预览去 HTML。
//  - openNoteInAnki 经 native `openNote` 传 noteId，native 回 true 时返回 true。
//  - 通道异常 / 形状异常时优雅降级（空列表 / false，不抛）。

const MethodChannel _channel = MethodChannel('app.hibiki.reader/anki');

class _ConfiguredAnkiRepository extends AnkiRepository {
  _ConfiguredAnkiRepository(this.settings);
  final AnkiSettings settings;
  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

AnkiSettings _settings() => AnkiSettings(
      selectedDeckId: 1,
      selectedNoteTypeId: 2,
      availableDecks: const <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
      availableNoteTypes: const <AnkiNoteType>[
        AnkiNoteType(
          id: 2,
          name: 'Hibiki',
          fields: <String>['Expression', 'Reading'],
        ),
      ],
      fieldMappings: const <String, String>{
        'Expression': '{expression}',
        'Reading': '{reading}',
      },
    );

void _mockChannel(
  List<MethodCall> calls,
  Future<Object?> Function(MethodCall call) responder,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (MethodCall call) async {
    calls.add(call);
    return responder(call);
  });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('findMatchingNotes', () {
    test('parses native [{noteId, preview}] into MinedNoteRef list', () async {
      final calls = <MethodCall>[];
      _mockChannel(calls, (call) async {
        if (call.method == 'findNotesByContent') {
          return <Object?>[
            <String, Object?>{'noteId': 1654000000999, 'preview': '<b>勉強</b>'},
            <String, Object?>{'noteId': 1654000000123, 'preview': '勉強 '},
          ];
        }
        fail('unexpected channel call: ${call.method}');
      });

      final repo = _ConfiguredAnkiRepository(_settings());
      final matches = await repo.findMatchingNotes('勉強', 'べんきょう');

      expect(matches.map((m) => m.noteId).toList(),
          [1654000000999, 1654000000123]);
      // 预览去 HTML / trim。
      expect(matches.first.preview, '勉強');
      expect(matches.last.preview, '勉強');
      // 通道参数正确（reading 过滤 + reading 字段索引 = 1）。
      final call = calls.single;
      expect(call.method, 'findNotesByContent');
      final args = call.arguments as Map;
      expect(args['key'], '勉強');
      expect(args['reading'], 'べんきょう');
      expect(args['models'], ['Hibiki']);
      expect(args['readingFieldIndices'], [1]);
    });

    test('returns empty list on channel error (no throw)', () async {
      _mockChannel(<MethodCall>[], (call) async {
        throw PlatformException(code: 'ANKI_PROVIDER_ERROR');
      });
      final repo = _ConfiguredAnkiRepository(_settings());
      final matches = await repo.findMatchingNotes('勉強', 'べんきょう');
      expect(matches, isEmpty);
    });

    test('returns empty list when native gives a non-list (no throw)',
        () async {
      _mockChannel(<MethodCall>[], (call) async => null);
      final repo = _ConfiguredAnkiRepository(_settings());
      final matches = await repo.findMatchingNotes('勉強', '');
      expect(matches, isEmpty);
    });
  });

  group('openNoteInAnki', () {
    test('forwards noteId to native openNote and returns true', () async {
      final calls = <MethodCall>[];
      _mockChannel(calls, (call) async {
        if (call.method == 'openNote') return true;
        fail('unexpected channel call: ${call.method}');
      });
      final repo = _ConfiguredAnkiRepository(_settings());
      final ok = await repo.openNoteInAnki(1654000000999);
      expect(ok, isTrue);
      expect((calls.single.arguments as Map)['noteId'], 1654000000999);
    });

    test('returns false on channel error (no throw)', () async {
      _mockChannel(<MethodCall>[], (call) async {
        throw PlatformException(code: 'OPEN_NOTE_FAILED');
      });
      final repo = _ConfiguredAnkiRepository(_settings());
      expect(await repo.openNoteInAnki(1), isFalse);
    });
  });
}
