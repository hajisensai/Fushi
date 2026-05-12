import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/src/database/database.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/tag_management_page.dart';
import 'package:hibiki/i18n/strings.g.dart';

final selectedTagIdsProvider = StateProvider<Set<int>>((_) => {});

final filteredBookIdsProvider = FutureProvider<Set<int>?>((ref) async {
  final tagIds = ref.watch(selectedTagIdsProvider);
  if (tagIds.isEmpty) return null;
  final db = ref.watch(appProvider).database;
  return db.getBookIdsForAnyTag(tagIds);
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
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
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
                    return FilterChip(
                      selected: isSelected,
                      avatar: CircleAvatar(
                        backgroundColor: Color(tag.colorValue),
                        radius: 6,
                      ),
                      label: Text(tag.name),
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
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              children: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
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
