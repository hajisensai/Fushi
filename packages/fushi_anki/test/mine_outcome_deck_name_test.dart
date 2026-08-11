import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

// BUG-1549：成功 toast「已添加到『…』」的牌组名必须由后端随 MineOutcome 带回
// **实际落卡**的 deck 名，而不是调用方事后读 settings.selectedDeckName 猜。
// 回归形状：旧存档/旧 Profile 快照只有 selectedDeckId 没有 selectedDeckName 时，
// 后端按 id 照样解析出 deck 并成功落卡，但 selectedDeckName 是 null → toast 空引号。
// 本测试用「只有 id、name 为 null」的 legacy 设置钉死三条路径都带回真实牌组名。

class _RecordingAnkiConnectService extends AnkiConnectService {
  final List<String> addedDecks = <String>[];
  final List<int> updatedNoteIds = <int>[];

  @override
  Future<bool> mediaFileExists(String filename) async => false;

  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) async {}

  @override
  Future<int?> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
    bool allowDuplicate = false,
    AnkiDuplicateScope duplicateScope = AnkiDuplicateScope.deck,
  }) async {
    addedDecks.add(deckName);
    return 42;
  }

  @override
  Future<void> updateNoteFields(int noteId, Map<String, String> fields) async {
    updatedNoteIds.add(noteId);
  }
}

class _ConfiguredAnkiConnectRepository extends AnkiConnectRepository {
  _ConfiguredAnkiConnectRepository({
    required AnkiConnectService service,
    required this.settings,
  }) : super(service: service);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

class _ConfiguredAnkiRepository extends AnkiRepository {
  _ConfiguredAnkiRepository(this.settings);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

/// 旧存档形状：只有 selectedDeckId，selectedDeckName 刻意为 null。
AnkiSettings _legacyIdOnlySettings() => AnkiSettings(
      selectedDeckId: 1,
      selectedNoteTypeId: 2,
      availableDecks: const <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
      availableNoteTypes: const <AnkiNoteType>[
        AnkiNoteType(id: 2, name: 'Hibiki', fields: <String>['Expression']),
      ],
      fieldMappings: const <String, String>{'Expression': '{expression}'},
      allowDupes: true,
    );

const String _payload = '{"expression":"勉強","reading":"べんきょう"}';

void main() {
  group('BUG-1549 成功结果带回实际落卡牌组名（settings 只有 id、name 为 null）', () {
    test('AnkiConnect mineEntry：outcome.deckName = 实际落卡的 deck 名', () async {
      final _RecordingAnkiConnectService service =
          _RecordingAnkiConnectService();
      final _ConfiguredAnkiConnectRepository repo =
          _ConfiguredAnkiConnectRepository(
        service: service,
        settings: _legacyIdOnlySettings(),
      );
      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: ''),
      );
      expect(outcome.result, MineResult.success);
      // 卡确实落进了按 id 解析出的 deck……
      expect(service.addedDecks, <String>['Mining']);
      // ……成功结果必须带回同一个名字（此前这里是 null → toast「已添加到『』」）。
      expect(outcome.deckName, 'Mining');
    });

    test('AnkiConnect updateMinedNote：覆写成功同样带回牌组名', () async {
      final _RecordingAnkiConnectService service =
          _RecordingAnkiConnectService();
      final _ConfiguredAnkiConnectRepository repo =
          _ConfiguredAnkiConnectRepository(
        service: service,
        settings: _legacyIdOnlySettings(),
      );
      final MineOutcome outcome = await repo.updateMinedNote(
        noteId: 42,
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: ''),
      );
      expect(outcome.result, MineResult.success);
      expect(service.updatedNoteIds, <int>[42]);
      expect(outcome.deckName, 'Mining');
    });

    test('AnkiDroid mineEntry：outcome.deckName 与 AnkiConnect 对称', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const MethodChannel channel = MethodChannel('app.fushi.reader/anki');
      final List<String> addedDecks = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        switch (call.method) {
          case 'addNote':
            final Map<String, dynamic> args =
                Map<String, dynamic>.from(call.arguments as Map);
            addedDecks.add(args['deck'] as String);
            return 42;
          default:
            fail('Unexpected AnkiDroid channel call: ${call.method}');
        }
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final _ConfiguredAnkiRepository repo =
          _ConfiguredAnkiRepository(_legacyIdOnlySettings());
      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: ''),
      );
      expect(outcome.result, MineResult.success);
      expect(addedDecks, <String>['Mining']);
      expect(outcome.deckName, 'Mining');
    });
  });
}
