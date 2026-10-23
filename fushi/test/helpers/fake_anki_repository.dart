import 'package:fushi_anki/fushi_anki.dart';

class FakeAnkiRepository extends BaseAnkiRepository {
  AnkiSettings _settings = const AnkiSettings();

  @override
  Future<AnkiSettings> loadSettings() async => _settings;

  @override
  Future<void> saveSettings(AnkiSettings settings) async {
    _settings = settings;
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() => throw UnimplementedError();

  /// 收到的制卡 / 覆写上下文（按调用顺序），供断言制卡来源等字段。
  final List<AnkiMiningContext> minedContexts = <AnkiMiningContext>[];

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) {
    minedContexts.add(context);
    throw UnimplementedError();
  }

  @override
  Future<MineOutcome> updateMinedNote({
    required int noteId,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) {
    minedContexts.add(context);
    return super.updateMinedNote(
      noteId: noteId,
      rawPayloadJson: rawPayloadJson,
      context: context,
    );
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) =>
      throw UnimplementedError();

  @override
  Future<bool> createDeck(String name) => throw UnimplementedError();
}
