import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/tag_management_page.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_widgets.dart';
import 'package:hibiki/src/utils/components/hibiki_divider.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/i18n/strings.g.dart';

final selectedTagIdsProvider = StateProvider<Set<int>>((_) => {});

final filteredBookIdsProvider = FutureProvider<Set<int>?>((ref) async {
  final tagIds = ref.watch(selectedTagIdsProvider);
  if (tagIds.isEmpty) return null;
  final db = ref.watch(appProvider).database;
  return db.getBookIdsForAllTags(tagIds);
});

final allTagsProvider = FutureProvider<List<BookTagRow>>((ref) async {
  final db = ref.watch(appProvider).database;
  return db.getAllTags();
});

final bookTagMapProvider =
    FutureProvider<Map<int, List<BookTagRow>>>((ref) async {
  final db = ref.watch(appProvider).database;
  final tags = await db.getAllTags();
  final mappings = await db.getAllBookTagMappings();
  final tagById = {for (final t in tags) t.id: t};
  final Map<int, List<BookTagRow>> result = {};
  for (final m in mappings) {
    final tag = tagById[m.tagId];
    if (tag != null) {
      result.putIfAbsent(m.bookId, () => []).add(tag);
    }
  }
  return result;
});

final srtBookTagMapProvider =
    FutureProvider<Map<int, List<BookTagRow>>>((ref) async {
  final db = ref.watch(appProvider).database;
  final tags = await db.getAllTags();
  final mappings = await db.getAllSrtBookTagMappings();
  final tagById = {for (final t in tags) t.id: t};
  final Map<int, List<BookTagRow>> result = {};
  for (final m in mappings) {
    final tag = tagById[m.tagId];
    if (tag != null) {
      result.putIfAbsent(m.srtBookId, () => []).add(tag);
    }
  }
  return result;
});

final filteredSrtBookIdsProvider = FutureProvider<Set<int>?>((ref) async {
  final tagIds = ref.watch(selectedTagIdsProvider);
  if (tagIds.isEmpty) return null;
  final db = ref.watch(appProvider).database;
  return db.getSrtBookIdsForAllTags(tagIds);
});

class TagFilterSheet extends ConsumerStatefulWidget {
  const TagFilterSheet({super.key});

  @override
  ConsumerState<TagFilterSheet> createState() => _TagFilterSheetState();
}

class _TagFilterSheetState extends ConsumerState<TagFilterSheet> {
  List<BookTagRow>? _tags;

  @override
  void initState() {
    super.initState();
    _loadTags();
  }

  Future<void> _loadTags() async {
    final db = ref.read(appProvider).database;
    final tags = await db.getAllTags();
    if (mounted) setState(() => _tags = tags);
  }

  @override
  Widget build(BuildContext context) {
    final selectedIds = ref.watch(selectedTagIdsProvider);
    final theme = Theme.of(context);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              t.tag_filter_title,
              style: theme.textTheme.titleMedium,
            ),
          ),
          if (_tags == null)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(child: adaptiveIndicator(context: context)),
            )
          else if (_tags!.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                t.tag_no_tags_hint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: _tags!.map((tag) {
                    final isSelected = selectedIds.contains(tag.id);
                    return HibikiSelectableChip(
                      selected: isSelected,
                      avatar: CircleAvatar(
                        backgroundColor: Color(tag.colorValue),
                        radius: 6,
                      ),
                      label: tag.name,
                      onSelected: (selected) {
                        final current =
                            Set<int>.from(ref.read(selectedTagIdsProvider));
                        if (selected) {
                          current.add(tag.id);
                        } else {
                          current.remove(tag.id);
                        }
                        ref.read(selectedTagIdsProvider.notifier).state =
                            current;
                      },
                    );
                  }).toList(),
                ),
              ),
            ),
          const HibikiDivider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              children: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      adaptivePageRoute(
                        builder: (_) => const TagManagementPage(),
                      ),
                    );
                  },
                  child: Text(t.tag_manage),
                ),
                const Spacer(),
                if (selectedIds.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      ref.read(selectedTagIdsProvider.notifier).state = {};
                    },
                    child: Text(t.tag_clear_filter),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
