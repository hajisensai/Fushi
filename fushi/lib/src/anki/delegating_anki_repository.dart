/// Anki 仓库的**纯委派**基类：所有后端会覆盖的成员都原样转给 [inner]。
///
/// 仓库层装饰器（制卡后自动重排、待发制卡队列……）的语义都是「行为与被包装的
/// 仓库完全一致，只在 [mineEntry] 上多做一件事」。Dart 没有自动转发，漏委派一个
/// 成员不会报错——调用会静默掉回 [BaseAnkiRepository] 的降级默认（例如
/// `supportsNoteTypeEditing` 变 false、`noteFields` 恒返回 null）。所以这份委派
/// 清单只写**一次**，放在这里；装饰器继承本类，只覆盖自己真正改变行为的方法。
///
/// 守卫测试 `fushi/test/anki/auto_reposition_repository_delegation_test.dart`
/// 钉死本文件：基类里新增或被任一后端覆盖的成员，没在这里委派就会红。
library;

import 'package:fushi_anki/fushi_anki.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 把除构造外的一切转给 [inner] 的 Anki 仓库。子类覆盖 [mineEntry] 等需要
/// 附加行为的方法。
abstract class DelegatingAnkiRepository extends BaseAnkiRepository {
  DelegatingAnkiRepository({required BaseAnkiRepository inner})
    : _inner = inner;

  final BaseAnkiRepository _inner;

  /// 被包装的仓库。
  BaseAnkiRepository get inner => _inner;

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) => inner.mineEntry(rawPayloadJson: rawPayloadJson, context: context);

  @override
  Future<String?> readSettingsJson(SharedPreferences prefs) =>
      inner.readSettingsJson(prefs);

  @override
  Future<AnkiSettings> loadSettings() => inner.loadSettings();

  @override
  Future<void> saveSettings(AnkiSettings settings) =>
      inner.saveSettings(settings);

  @override
  Future<AnkiSettings> updateSettings(
    AnkiSettings Function(AnkiSettings) transform,
  ) => inner.updateSettings(transform);

  @override
  Future<AnkiFetchResult> fetchConfiguration() => inner.fetchConfiguration();

  @override
  Future<MineOutcome> updateMinedNote({
    required int noteId,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) => inner.updateMinedNote(
    noteId: noteId,
    rawPayloadJson: rawPayloadJson,
    context: context,
  );

  @override
  Future<int?> findOverwriteTargetNoteId(String expression, String reading) =>
      inner.findOverwriteTargetNoteId(expression, reading);

  @override
  Future<List<MinedNoteRef>> findMatchingNotes(
    String expression,
    String reading,
  ) => inner.findMatchingNotes(expression, reading);

  @override
  Future<Map<String, String>?> noteFields(int noteId) =>
      inner.noteFields(noteId);

  @override
  Future<bool> openNoteInAnki(int noteId) => inner.openNoteInAnki(noteId);

  @override
  Future<Map<String, String>> prepareSourceNoteFields({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) => inner.prepareSourceNoteFields(
    rawPayloadJson: rawPayloadJson,
    context: context,
  );

  @override
  Future<List<int>> findSourceNoteCandidates(String sourceId) =>
      inner.findSourceNoteCandidates(sourceId);

  @override
  Future<Map<String, String>?> sourceNoteFields(int noteId) =>
      inner.sourceNoteFields(noteId);

  @override
  Future<void> writeSourceNoteFields(int noteId, Map<String, String> fields) =>
      inner.writeSourceNoteFields(noteId, fields);

  @override
  Future<AnkiSourceNote?> readSourceNote(String sourceId) =>
      inner.readSourceNote(sourceId);

  @override
  Future<void> patchSourceNote({
    required AnkiSourceNote original,
    required Map<String, String> fields,
  }) => inner.patchSourceNote(original: original, fields: fields);

  @override
  Future<AnkiOpenWordOutcome> openWordInAnki(
    String expression,
    String reading,
  ) => inner.openWordInAnki(expression, reading);

  @override
  Future<Set<int>> findDeletedNotes(Set<int> noteIds) =>
      inner.findDeletedNotes(noteIds);

  @override
  Future<bool> isDuplicate(String expression, String reading) =>
      inner.isDuplicate(expression, reading);

  /// 不委派的后果不是「少个功能」而是**正确性回归**：装饰器会拿到基类默认 `true`，
  /// 于是开了自动重排的 iOS 用户点 ✓ 时，编排层以为「这个后端能回读 Anki」，把
  /// AnkiMobile 恒空的反查当成「卡已被删」，默默再制一张重复卡。
  @override
  bool get canVerifyExistingCards => inner.canVerifyExistingCards;

  @override
  bool get switchesAppPerNote => inner.switchesAppPerNote;

  @override
  Future<bool> forgetMinedCard(String expression) =>
      inner.forgetMinedCard(expression);

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) =>
      inner.createNoteType(template);

  @override
  Future<bool> createDeck(String name) => inner.createDeck(name);

  @override
  bool get supportsNoteTypeEditing => inner.supportsNoteTypeEditing;

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(String modelName) =>
      inner.readNoteTypeDefinition(modelName);

  @override
  Future<bool?> rendersSynchronizedClip() => inner.rendersSynchronizedClip();

  @override
  Future<bool> updateNoteTypeStyling(String modelName, String css) =>
      inner.updateNoteTypeStyling(modelName, css);

  @override
  Future<bool> updateNoteTypeTemplates(
    String modelName,
    List<AnkiCardTemplate> templates,
  ) => inner.updateNoteTypeTemplates(modelName, templates);

  @override
  bool get supportsMediaMaintenance => inner.supportsMediaMaintenance;

  @override
  Future<bool> probeMediaMaintenance() => inner.probeMediaMaintenance();

  @override
  bool get supportsMediaMaintenanceProgress =>
      inner.supportsMediaMaintenanceProgress;

  @override
  Future<AnkiMediaDedupReport?> runMediaDedup({
    bool dryRun = false,
    Future<void> Function(Map<String, dynamic> entry)? onJournal,
    AnkiMediaDedupOnProgress? onProgress,
    bool Function()? shouldCancel,
  }) => inner.runMediaDedup(
    dryRun: dryRun,
    onJournal: onJournal,
    onProgress: onProgress,
    shouldCancel: shouldCancel,
  );

  @override
  bool get supportsDeckReposition => inner.supportsDeckReposition;

  @override
  Future<List<AnkiCardInfo>> listNewCards(String deckName) =>
      inner.listNewCards(deckName);

  @override
  Future<AnkiCardDueWriteResult> setNewCardPositions(
    List<AnkiCardDueUpdate> updates,
  ) => inner.setNewCardPositions(updates);
}
