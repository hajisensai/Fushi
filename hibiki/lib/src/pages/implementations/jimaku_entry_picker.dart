import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/jimaku_client.dart';
import 'package:hibiki/utils.dart';

/// Jimaku 字幕来源选择器。
///
/// 搜索结果中的每个 [JimakuEntry] 都是一个独立字幕条目；整季合集字幕同样
/// 是一个条目，选中后由调用方按集号从条目内匹配文件。这里不再把多个条目
/// 静默合并，避免同一番剧的不同字幕版本串在一起。
class JimakuEntryPicker extends StatelessWidget {
  const JimakuEntryPicker({
    required this.entries,
    required this.selectedEntryId,
    required this.onSelected,
    this.enabled = true,
    super.key,
  });

  final List<JimakuEntry> entries;
  final int? selectedEntryId;
  final ValueChanged<JimakuEntry> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          t.video_jimaku_source,
          style: theme.textTheme.labelMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final JimakuEntry entry in entries)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: ChoiceChip(
                  label: Text(
                    entry.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  tooltip: entry.name,
                  selected: selectedEntryId == entry.id,
                  onSelected: enabled ? (_) => onSelected(entry) : null,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          t.video_jimaku_source_hint,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class JimakuLanguagePicker extends StatelessWidget {
  const JimakuLanguagePicker({
    required this.selectedLanguage,
    required this.onSelected,
    this.enabled = true,
    super.key,
  });

  final String? selectedLanguage;
  final ValueChanged<String?> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        ChoiceChip(
          label: Text(t.video_jimaku_language_all),
          selected: selectedLanguage == null,
          onSelected: enabled ? (_) => onSelected(null) : null,
        ),
        for (final String language in kJimakuLanguageCodes)
          ChoiceChip(
            label: Text(jimakuLanguageLabel(language)),
            selected: selectedLanguage == language,
            onSelected: enabled ? (_) => onSelected(language) : null,
          ),
      ],
    );
  }
}
