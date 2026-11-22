/// 「移到分栏…」（拍板台 iR6ccUys9H）：把合集里的视频钉到某一季或 PV·特典栏，
/// 或改回「自动」（先看手动季集指定，再按文件名）。
///
/// 挂在合集详情页集卡的上下文菜单与多选底栏上；写
/// `video_collection_section_overrides`（稀疏覆盖，跟着文件走，合并合集 / 重新刮削
/// 都保留）。AI 走同一张表的控制通道 `video.section.set`。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/collection_season_groups.dart';

/// 对话框里「自动」一项的值（清掉手动分栏）。
const String kCollectionSectionAutoChoice = 'auto';

/// 下拉框的候选：自动 → 第 1..N 季（已有季 + 再多一季，便于新开一季）→ PV·特典。
/// 纯函数。
List<String> collectionSectionChoices(Iterable<String> existingKeys) {
  int maxSeason = 1;
  for (final String key in existingKeys) {
    final int? season = seasonNumberOfGroupKey(key);
    if (season != null && season > maxSeason) maxSeason = season;
  }
  return <String>[
    kCollectionSectionAutoChoice,
    for (int season = 1; season <= maxSeason + 1; season++) 's$season',
    kCollectionExtrasGroupKey,
  ];
}

/// 打开分栏选择框，确认后写库。返回是否改了。
///
/// [existingKeys]：合集现有的分栏键（决定下拉里列到第几季）；[initial]：单个文件时
/// 它当前的手动分栏（没有 = 「自动」）。
Future<bool> moveVideosToCollectionSection({
  required BuildContext context,
  required FushiDatabase database,
  required List<String> bookUids,
  required Iterable<String> existingKeys,
  String? initial,
}) async {
  if (bookUids.isEmpty) return false;
  final List<String> choices = collectionSectionChoices(existingKeys);
  final String start = initial != null && choices.contains(initial)
      ? initial
      : kCollectionSectionAutoChoice;
  final String? picked = await showAppDialog<String>(
    context: context,
    builder: (BuildContext context) =>
        _CollectionSectionDialog(choices: choices, initial: start),
  );
  if (picked == null) return false;
  if (picked == kCollectionSectionAutoChoice) {
    await database.clearVideoCollectionSectionOverrides(bookUids);
  } else {
    if (!isValidCollectionSectionKey(picked)) return false;
    await database.setVideoCollectionSectionOverrides(bookUids, picked);
  }
  database.notifyVideoLibraryChanged();
  FushiToast.show(
    msg: t.collection_section_saved,
    severity: ToastSeverity.success,
  );
  return true;
}

/// 分栏选项的文案：自动 / 第 N 季 / PV·特典。
String collectionSectionChoiceLabel(String choice) {
  if (choice == kCollectionSectionAutoChoice) return t.collection_section_auto;
  final int? season = seasonNumberOfGroupKey(choice);
  return season == null
      ? t.collection_group_extras
      : t.collection_group_season(n: season);
}

class _CollectionSectionDialog extends StatefulWidget {
  const _CollectionSectionDialog({
    required this.choices,
    required this.initial,
  });

  final List<String> choices;
  final String initial;

  @override
  State<_CollectionSectionDialog> createState() =>
      _CollectionSectionDialogState();
}

class _CollectionSectionDialogState extends State<_CollectionSectionDialog> {
  late String _value = widget.initial;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return FushiAlertDialog(
      icon: const FushiIcon(FushiIcons.viewAgenda),
      title: Text(t.collection_section_dialog_title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t.collection_section_hint,
              style: context.fushiType.bodyMedium.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FushiDropdownButtonFormField<String>(
              key: const ValueKey<String>('video-collection-section-choice'),
              value: _value,
              items: <DropdownMenuItem<String>>[
                for (final String choice in widget.choices)
                  DropdownMenuItem<String>(
                    value: choice,
                    child: Text(collectionSectionChoiceLabel(choice)),
                  ),
              ],
              onChanged: (String? value) {
                if (value == null) return;
                setState(() => _value = value);
              },
            ),
          ],
        ),
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.dialog_cancel,
          onPressed: () => Navigator.pop(context),
        ),
        FushiDialogAction(
          kind: FushiDialogActionKind.primary,
          label: t.dialog_save,
          onPressed: () => Navigator.pop(context, _value),
        ),
      ],
    );
  }
}
