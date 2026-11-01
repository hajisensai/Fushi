import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 「高级制卡」对话框的卡组分区：从 Anki 设置组装（纯函数，可单测）。
///
/// * 可选卡组 = 已拉取的 `availableDecks` 名字，按名字排序；没连过 Anki 时为空
///   （对话框只显示默认卡组名、不给下拉）。
/// * 默认卡组 = 一键「+」会写进的那个：与后端 `resolveSelectedDeck` 同口径（id 优先、
///   名字兜底）；两者都对不上列表时退回存档里的名字（旧存档 / 卡组刚被改名），
///   仍是 null 就表示尚未选择。
AdvancedMiningDeckSection buildAdvancedMiningDeckSection(
  AnkiSettings settings, {
  Future<void> Function(String deckName)? setDefaultDeck,
}) {
  final List<String> decks =
      settings.availableDecks.map((AnkiDeck d) => d.name).toSet().toList()
        ..sort();
  final AnkiDeck? selected =
      settings.availableDecks.firstWhereOrNull(
        (AnkiDeck d) => d.id == settings.selectedDeckId,
      ) ??
      (settings.selectedDeckName != null
          ? settings.availableDecks.firstWhereOrNull(
              (AnkiDeck d) => d.name == settings.selectedDeckName,
            )
          : null);
  return AdvancedMiningDeckSection(
    decks: decks,
    defaultDeckName: selected?.name ?? settings.selectedDeckName,
    setDefaultDeck: setDefaultDeck,
  );
}

/// 开窗函数用：读当前 Anki 设置并组装卡组分区。「同时设为默认卡组」走
/// [AnkiViewModel.selectDeck]（与设置页同一条持久化路径，id + 名字一起写），
/// 名字在这次读到的列表里找不到就不写（不凭空造卡组）。
Future<AdvancedMiningDeckSection> loadAdvancedMiningDeckSection(
  WidgetRef ref,
) async {
  final AnkiSettings settings = await ref
      .read(ankiRepositoryProvider)
      .loadSettings();
  return buildAdvancedMiningDeckSection(
    settings,
    setDefaultDeck: (String deckName) async {
      final AnkiDeck? deck = settings.availableDecks.firstWhereOrNull(
        (AnkiDeck d) => d.name == deckName,
      );
      if (deck == null) return;
      await ref.read(ankiViewModelProvider.notifier).selectDeck(deck);
    },
  );
}

/// 「高级制卡」的卡片字段分区：从字段映射组装（纯函数，可单测，反馈 -K86qlwBg6）。
///
/// * 字段 = 映射里模板非空的字段（映射顺序）；映射为空时返回 null（分区不渲染）。
/// * 显示哪些 = 用户记住的选择（只认映射里还在的名字）；[remembered] 为 null（从没
///   选过）时默认显示释义类字段（模板含 `glossary`）——反馈的原话就是「想改释义」。
AdvancedMiningFieldsSection? buildAdvancedMiningFieldsSection(
  AnkiSettings settings, {
  List<String>? remembered,
  Future<void> Function(Set<String> names)? setVisibleFields,
}) {
  final List<AdvancedMiningField> fields = <AdvancedMiningField>[
    for (final MapEntry<String, String> e in settings.fieldMappings.entries)
      if (e.value.trim().isNotEmpty)
        AdvancedMiningField(name: e.key, template: e.value.trim()),
  ];
  if (fields.isEmpty) return null;
  final Set<String> visible = remembered != null
      ? remembered.toSet()
      : <String>{
          for (final AdvancedMiningField f in fields)
            if (f.template.contains('glossary')) f.name,
        };
  return AdvancedMiningFieldsSection(
    fields: fields,
    visibleFields: <String>{
      for (final AdvancedMiningField f in fields)
        if (visible.contains(f.name)) f.name,
    },
    setVisibleFields: setVisibleFields,
  );
}

/// 开窗函数用：读当前 Anki 设置与记住的「显示哪些字段」组装卡片字段分区。
Future<AdvancedMiningFieldsSection?> loadAdvancedMiningFieldsSection(
  WidgetRef ref,
) async {
  final AnkiSettings settings = await ref
      .read(ankiRepositoryProvider)
      .loadSettings();
  final AppModel appModel = ref.read(appProvider);
  return buildAdvancedMiningFieldsSection(
    settings,
    remembered: appModel.advancedMiningVisibleFields,
    setVisibleFields: (Set<String> names) =>
        appModel.setAdvancedMiningVisibleFields(names.toList()..sort()),
  );
}
