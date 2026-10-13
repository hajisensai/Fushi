import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_anki/fushi_anki.dart' show AnkiDeck, AnkiSettings;
import 'package:fushi_core/fushi_core.dart' show ProfileRow;
import 'package:material_ui/material_ui.dart';

/// 制卡目标菜单里的一项：切到某个配置，或切到某个牌组。
@immutable
sealed class DictionaryPopupMiningTarget {
  const DictionaryPopupMiningTarget();
}

final class DictionaryPopupProfileTarget extends DictionaryPopupMiningTarget {
  const DictionaryPopupProfileTarget(this.profileId);
  final int profileId;

  @override
  bool operator ==(Object other) =>
      other is DictionaryPopupProfileTarget && other.profileId == profileId;

  @override
  int get hashCode => Object.hash('profile', profileId);
}

final class DictionaryPopupDeckTarget extends DictionaryPopupMiningTarget {
  const DictionaryPopupDeckTarget(this.deck);
  final AnkiDeck deck;

  @override
  bool operator ==(Object other) =>
      other is DictionaryPopupDeckTarget && other.deck.id == deck.id;

  @override
  int get hashCode => Object.hash('deck', deck.id);
}

/// 查词弹窗顶栏的「制卡目标」按钮（用户建议 #fiwDIpFep7，参照 Yomitan 弹窗里的
/// 配置下拉）：不离开弹窗就能切**配置**与**牌组**，下一次点 + 即按新目标制卡。
///
/// - 配置：走设置页同一条 [ProfileViewModel.switchProfile]。每份配置各自保存牌组、
///   笔记类型与字段映射（`ProfileKeys` 的 Anki 分类快照），所以「生词卡 / 纯音频卡」
///   这类不同笔记类型的组合，按配置切换即可整套换过去。
/// - 牌组：走 [AnkiViewModel.selectDeck]，与设置页的牌组选择同一个写入口。
///
/// 笔记类型**不**单独放进来：[AnkiViewModel.selectNoteType] 会把字段映射重置为
/// 该笔记类型的默认映射（非 Lapis 等于清空），弹窗里随手切一下就会毁掉用户配好的
/// 映射。需要换笔记类型请用配置承载。
///
/// 列表取自已缓存的 Anki 设置（`availableDecks`，设置页 / 上次连接时拉取）与配置
/// 表，打开菜单不发任何网络请求。
class DictionaryPopupMiningTargetButton extends ConsumerWidget {
  const DictionaryPopupMiningTargetButton({
    required this.constraints,
    super.key,
  });

  /// 与同组顶栏按钮一致的命中盒。
  final BoxConstraints constraints;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<DictionaryPopupMiningTarget>(
      key: const ValueKey<String>('popup_mining_target'),
      tooltip: t.popup_mining_target_switch,
      padding: EdgeInsets.zero,
      onSelected: (DictionaryPopupMiningTarget target) =>
          applyDictionaryPopupMiningTarget(ref, target),
      // 打开菜单时才读两个 provider：弹窗每次查词都会重建顶栏，常驻 watch 会让
      // 每个宿主（含不制卡的测试宿主）都去实例化 Anki / 配置仓库。
      itemBuilder: (BuildContext context) {
        final AnkiSettings settings = ref.read(ankiViewModelProvider).settings;
        final ProfileUiState profiles = ref.read(profileViewModelProvider);
        return buildDictionaryPopupMiningTargetItems(
          profiles: profiles.profiles,
          activeProfileId: profiles.activeProfileId,
          decks: settings.availableDecks,
          selectedDeckId: settings.selectedDeckId,
        );
      },
      child: ConstrainedBox(
        constraints: constraints,
        child: const Center(child: FushiIcon(FushiIcons.ankiCard, size: 20)),
      ),
    );
  }
}

/// 执行一次菜单选择（与设置页同一组写入口，不另写持久化）。
Future<void> applyDictionaryPopupMiningTarget(
  WidgetRef ref,
  DictionaryPopupMiningTarget target,
) {
  return switch (target) {
    DictionaryPopupProfileTarget(:final int profileId) =>
      ref.read(profileViewModelProvider.notifier).switchProfile(profileId),
    DictionaryPopupDeckTarget(:final AnkiDeck deck) =>
      ref.read(ankiViewModelProvider.notifier).selectDeck(deck),
  };
}

/// 菜单项（纯函数，测试直接断言）：配置一节 + 牌组一节，当前项打勾；某一节没有
/// 候选就整节不出。两节都没有时给一条不可点的提示行，菜单不会空着弹出来。
List<PopupMenuEntry<DictionaryPopupMiningTarget>>
buildDictionaryPopupMiningTargetItems({
  required List<ProfileRow> profiles,
  required int activeProfileId,
  required List<AnkiDeck> decks,
  required int? selectedDeckId,
}) {
  final List<PopupMenuEntry<DictionaryPopupMiningTarget>> items =
      <PopupMenuEntry<DictionaryPopupMiningTarget>>[];
  if (profiles.isNotEmpty) {
    items.add(_header(t.profile_label));
    for (final ProfileRow p in profiles) {
      items.add(
        CheckedPopupMenuItem<DictionaryPopupMiningTarget>(
          value: DictionaryPopupProfileTarget(p.id),
          checked: p.id == activeProfileId,
          child: Text(p.name),
        ),
      );
    }
  }
  if (decks.isNotEmpty) {
    if (items.isNotEmpty) items.add(const PopupMenuDivider());
    items.add(_header(t.anki_deck));
    for (final AnkiDeck d in decks) {
      items.add(
        CheckedPopupMenuItem<DictionaryPopupMiningTarget>(
          value: DictionaryPopupDeckTarget(d),
          checked: d.id == selectedDeckId,
          child: Text(d.name),
        ),
      );
    }
  }
  if (items.isEmpty) items.add(_header(t.popup_mining_target_empty));
  return items;
}

PopupMenuItem<DictionaryPopupMiningTarget> _header(String label) =>
    PopupMenuItem<DictionaryPopupMiningTarget>(
      enabled: false,
      height: 32,
      child: Text(label),
    );
