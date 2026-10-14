import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
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
