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
    this.inventories = const <int, JimakuFileInventory>{},
    this.loadingEntryIds = const <int>{},
    this.failedEntryIds = const <int>{},
    this.enabled = true,
    super.key,
  });

  final List<JimakuEntry> entries;
  final int? selectedEntryId;
  final ValueChanged<JimakuEntry> onSelected;
  final Map<int, JimakuFileInventory> inventories;
  final Set<int> loadingEntryIds;
  final Set<int> failedEntryIds;
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
        for (final JimakuEntry entry in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _buildEntryChoice(context, entry),
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

  Widget _buildEntryChoice(BuildContext context, JimakuEntry entry) {
    final ThemeData theme = Theme.of(context);
    final bool selected = selectedEntryId == entry.id;
    return HibikiCard(
      key: ValueKey<String>('jimaku_entry_${entry.id}'),
      selected: selected,
      borderColor: selected
          ? theme.colorScheme.primary
          : theme.colorScheme.outlineVariant,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: enabled ? () => onSelected(entry) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  entry.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  <String>[
                    'Jimaku #${entry.id}',
                    if (entry.anilistId != null) 'AniList #${entry.anilistId}',
                  ].join(' · '),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                _buildInventorySummary(theme, entry.id),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInventorySummary(ThemeData theme, int entryId) {
    if (loadingEntryIds.contains(entryId)) {
      return Row(
        children: <Widget>[
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 6),
          Text(t.video_jimaku_source_loading, style: theme.textTheme.bodySmall),
        ],
      );
    }
    if (failedEntryIds.contains(entryId)) {
      return Text(
        t.video_jimaku_source_failed,
        style:
            theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
      );
    }
    final JimakuFileInventory? inventory = inventories[entryId];
    if (inventory == null) {
      return Text(
        t.video_jimaku_source_hint,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    if (inventory.files.isEmpty) {
      return Text(
        t.video_jimaku_no_results,
        style:
            theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
      );
    }
    final String languages = inventory.languages.isEmpty
        ? t.video_jimaku_language_unknown
        : inventory.languages.map(jimakuLanguageLabel).join(' / ');
    return Text(
      t.video_jimaku_source_summary(
        files: inventory.files.length,
        episodes: inventory.episodes.length,
        languages: languages,
      ),
      style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
