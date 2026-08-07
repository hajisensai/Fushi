import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/tag_management_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/hibiki_design_tokens.dart';
import 'package:fushi/src/utils/components/hibiki_material_components.dart';
import 'package:fushi/i18n/strings.g.dart';

final selectedTagIdsProvider = StateProvider<Set<int>>((_) => {});

final filteredBookIdsProvider = FutureProvider<Set<String>?>((ref) async {
  final tagIds = ref.watch(selectedTagIdsProvider);
  if (tagIds.isEmpty) return null;
  final db = ref.watch(appProvider).database;
  return db.getBookKeysForAllTags(tagIds);
});

final allTagsProvider = FutureProvider<List<BookTagRow>>((ref) async {
  final db = ref.watch(appProvider).database;
  return db.getAllTags();
});

final bookTagMapProvider =
    FutureProvider<Map<String, List<BookTagRow>>>((ref) async {
  final db = ref.watch(appProvider).database;
  final tags = await db.getAllTags();
  final mappings = await db.getAllBookTagMappings();
  final tagById = {for (final t in tags) t.id: t};
  final Map<String, List<BookTagRow>> result = {};
  for (final m in mappings) {
    final tag = tagById[m.tagId];
    if (tag != null) {
      result.putIfAbsent(m.bookKey, () => []).add(tag);
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

/// 合集 → 标签列表（keyed by collectionId）。与 [bookTagMapProvider] 等同形，
/// 共用同一 [BookTags] 标签池。让书架/视频列表里的合集行也能展示已打的标签 chip
/// （详情页早有展示，列表行此前没有——用户实报「打了标签但列表上看不见」）。
final collectionTagMapProvider =
    FutureProvider<Map<int, List<BookTagRow>>>((ref) async {
  final db = ref.watch(appProvider).database;
  final tags = await db.getAllTags();
  final mappings = await db.getAllCollectionTagMappings();
  final tagById = {for (final t in tags) t.id: t};
  final Map<int, List<BookTagRow>> result = {};
  for (final m in mappings) {
    final tag = tagById[m.tagId];
    if (tag != null) {
      result.putIfAbsent(m.collectionId, () => []).add(tag);
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

/// 视频书 → 标签列表（keyed by bookUid）。与 [bookTagMapProvider] /
/// [srtBookTagMapProvider] 同形，三者共用同一 [BookTags] 标签池。
final videoBookTagMapProvider =
    FutureProvider<Map<String, List<BookTagRow>>>((ref) async {
  final db = ref.watch(appProvider).database;
  final tags = await db.getAllTags();
  final mappings = await db.getAllVideoBookTagMappings();
  final tagById = {for (final t in tags) t.id: t};
  final Map<String, List<BookTagRow>> result = {};
  for (final m in mappings) {
    final tag = tagById[m.tagId];
    if (tag != null) {
      result.putIfAbsent(m.bookUid, () => []).add(tag);
    }
  }
  return result;
});

/// 当前标签筛选下命中的视频 bookUid 集合（共享 [selectedTagIdsProvider]，与
/// 书架/SRT 联动）；无筛选时返回 null（= 不过滤）。
final filteredVideoBookUidsProvider = FutureProvider<Set<String>?>((ref) async {
  final tagIds = ref.watch(selectedTagIdsProvider);
  if (tagIds.isEmpty) return null;
  final db = ref.watch(appProvider).database;
  return db.getVideoBookUidsForAllTags(tagIds);
});

/// 游戏 → 用户标签列表（keyed by `galgames.id`）。与 [bookTagMapProvider] /
/// [videoBookTagMapProvider] 同形，共用同一 [BookTags] 标签池（BUG-1113：游戏此前
/// 根本没有映射表，接不进这套共享标签体系）。
///
/// 注意与游戏的**元数据标签**（bgm/vndb 刮削来的字符串，`GalgameEntry.tags`）区分：
/// 那是外部事实、另一条筛选轴，由游戏库筛选面板按名筛，不进这个用户标签池。
final gameTagMapProvider =
    FutureProvider<Map<String, List<BookTagRow>>>((ref) async {
  final db = ref.watch(appProvider).database;
  final tags = await db.getAllTags();
  final mappings = await db.getAllGameTagMappings();
  final tagById = {for (final t in tags) t.id: t};
  final Map<String, List<BookTagRow>> result = {};
  for (final m in mappings) {
    final tag = tagById[m.tagId];
    if (tag != null) {
      result.putIfAbsent(m.gameId, () => []).add(tag);
    }
  }
  return result;
});

/// 当前标签筛选下命中的游戏 id 集合（共享 [selectedTagIdsProvider]，与书架 / 视频
/// 联动）；无筛选时返回 null（= 不过滤）。
final filteredGameIdsProvider = FutureProvider<Set<String>?>((ref) async {
  final tagIds = ref.watch(selectedTagIdsProvider);
  if (tagIds.isEmpty) return null;
  final db = ref.watch(appProvider).database;
  return db.getGameIdsForAllTags(tagIds);
});

/// 含【全部】选中标签的合集 id（无选中标签时 null = 不过滤）。合集卡按此显隐。
final filteredCollectionIdsProvider = FutureProvider<Set<int>?>((ref) async {
  final Set<int> tagIds = ref.watch(selectedTagIdsProvider);
  if (tagIds.isEmpty) return null;
  final db = ref.watch(appProvider).database;
  return db.getCollectionIdsForAllTags(tagIds);
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final selectedIds = ref.watch(selectedTagIdsProvider);
    final bool hasScrollableTags = _tags != null && _tags!.isNotEmpty;

    return HibikiModalSheetFrame(
      title: t.tag_filter_title,
      leadingIcon: Icons.sell_outlined,
      scrollable: hasScrollableTags,
      bodyPadding: hasScrollableTags
          ? EdgeInsets.symmetric(horizontal: tokens.spacing.page)
          : EdgeInsets.zero,
      body: _buildBody(context, selectedIds),
      footer: Row(
        children: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                adaptivePageRoute(
                  context: context,
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
    );
  }

  Widget _buildBody(BuildContext context, Set<int> selectedIds) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final List<BookTagRow>? tags = _tags;
    if (tags == null) {
      return Padding(
        padding: EdgeInsets.all(tokens.spacing.page + tokens.spacing.card),
        child: Center(child: adaptiveIndicator(context: context)),
      );
    }
    if (tags.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(tokens.spacing.card + tokens.spacing.gap),
        child: Text(
          t.tag_no_tags_hint,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap / 2,
      children: tags.map((tag) {
        final isSelected = selectedIds.contains(tag.id);
        return HibikiSelectableChip(
          selected: isSelected,
          avatar: CircleAvatar(
            backgroundColor: Color(tag.colorValue),
            radius: 6,
          ),
          label: tag.name,
          onSelected: (selected) {
            final current = Set<int>.from(ref.read(selectedTagIdsProvider));
            if (selected) {
              current.add(tag.id);
            } else {
              current.remove(tag.id);
            }
            ref.read(selectedTagIdsProvider.notifier).state = current;
          },
        );
      }).toList(),
    );
  }
}
