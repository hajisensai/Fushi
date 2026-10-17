import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart'
    show kDictionaryPopupTopActionIconSize;
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_anki/fushi_anki.dart' show AnkiDeck;
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
///
/// 两个视图模型都是**构造后异步装载**的（`AnkiViewModel._loadSettings` /
/// `ProfileViewModel._load`），切配置时 `ref.invalidate(ankiRepositoryProvider)`
/// 又会把两者重建成空态再装载一遍。所以这里在 build 里 `watch` 两者——provider
/// 随按钮常驻、装载完成即重建本按钮，菜单项取自已就绪的真值；任一方还在装载时按钮
/// 不可点（[dictionaryPopupMiningTargetReady]），不会弹出缺节或勾错的菜单。按钮只在
/// 制卡宿主里出现（`showMiningTargetSwitch`），不制卡的宿主不会实例化这两个仓库。
class DictionaryPopupMiningTargetButton extends ConsumerWidget {
  const DictionaryPopupMiningTargetButton({
    required this.constraints,
    super.key,
  });

  /// 与同组顶栏按钮一致的命中盒。
  final BoxConstraints constraints;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AnkiUiState anki = ref.watch(ankiViewModelProvider);
    final ProfileUiState profiles = ref.watch(profileViewModelProvider);
    return FushiPopupMenuButton<DictionaryPopupMiningTarget>(
      key: const ValueKey<String>('popup_mining_target'),
      tooltip: t.popup_mining_target_switch,
      padding: EdgeInsets.zero,
      enabled: dictionaryPopupMiningTargetReady(anki: anki, profiles: profiles),
      onSelected: (DictionaryPopupMiningTarget target) => unawaited(
        runDictionaryPopupMiningTargetSwitch(
          () => applyDictionaryPopupMiningTarget(ref, target),
          notifyFailure: _toastSwitchFailure,
        ),
      ),
      itemBuilder: (BuildContext context) =>
          buildDictionaryPopupMiningTargetItems(
            profiles: profiles.profiles,
            activeProfileId: profiles.activeProfileId,
            decks: anki.settings.availableDecks,
            selectedDeckId: anki.settings.selectedDeckId,
          ),
      child: ConstrainedBox(
        constraints: constraints,
        child: const Center(
          child: FushiIcon(
            FushiIcons.ankiCard,
            size: kDictionaryPopupTopActionIconSize,
          ),
        ),
      ),
    );
  }
}

/// 两个视图模型的异步首装是否都已完成：完成前列表是构造时的空占位，不是真值。
bool dictionaryPopupMiningTargetReady({
  required AnkiUiState anki,
  required ProfileUiState profiles,
}) => anki.settingsLoaded && !profiles.isLoading;

void _toastSwitchFailure(String message) =>
    FushiToast.show(msg: message, severity: ToastSeverity.error);

/// 执行一次菜单选择并兜住失败：写库（切配置 / 写牌组设置）失败时记日志并经
/// [notifyFailure] 告知用户，而不是让 Future 的错误落成未处理的 zone 错误、
/// 用户点了没反应也不知道为什么。返回是否成功。
Future<bool> runDictionaryPopupMiningTargetSwitch(
  Future<void> Function() apply, {
  required void Function(String message) notifyFailure,
}) async {
  try {
    await apply();
    return true;
  } catch (error, stack) {
    debugPrint('[popup] mining target switch failed: $error\n$stack');
    notifyFailure(t.popup_mining_target_switch_failed(error: '$error'));
    return false;
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
