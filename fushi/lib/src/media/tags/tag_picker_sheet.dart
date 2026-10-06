/// 共享标签选择器：书架 / 漫画库 / 视频库 / 游戏库 / 合集详情给一个或多个条目、
/// 合集打标签都走这里（取代各页手抄的 TagPickerPage 列表与批量三态弹窗）。
///
/// - 窄屏（宽 < [kTagPickerWideBreakpoint]）底部 sheet，宽屏弹层（≈560 宽）。
/// - 单目标：勾选**即时落库**（与旧 TagPickerPage 同语义）。多目标：每个标签三态
///   （全有 / 部分 / 全无），点击在「原状 → 全加 → 全去」间循环，「应用」统一落库。
/// - 顶部搜索（[matchesMediaSearch] 同口径归一化）；没有同名标签时一键「新建“xxx”」
///   并选中。已选标签以 input chip 排在上方，全部标签以 filter chip 云排在下方。
/// - 目标里含合集时多一个「作用于：合集本身 / 合集内全部条目」分段，二选一并附说明：
///   挂在合集上 = 按标签筛选时整组出现；成员模式 = 逐个打到合集里的每一项，合集不变。
library;

import 'package:drift/native.dart' show SqliteException;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/tags/tag_chips.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/tag_management_page.dart'
    show TagEditDialog, TagEditResult, kTagPresetColors;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 选择器从底部 sheet 换成居中弹层的窗口宽度。
const double kTagPickerWideBreakpoint = 600;

/// 一次打标签的目标集合。
@immutable
class TagTargets {
  const TagTargets({
    this.media = const <MediaRef>[],
    this.collectionIds = const <int>[],
  });

  /// 条目：epub 用 bookKey，srt 用 uid，video 用 bookUid，game 用 galgames.id。
  final List<MediaRef> media;

  /// 合集（media_collections 主键）。
  final List<int> collectionIds;

  int get count => media.length + collectionIds.length;
  bool get isEmpty => count == 0;
}

/// 「含合集的目标」把标签打到哪儿。
enum TagCollectionScope { collection, members }

/// 打开共享标签选择器。返回 true = 落库有改动（调用方据此刷新标签 provider）。
Future<bool> showTagPicker(
  BuildContext context, {
  required TagTargets targets,
  String? title,
}) async {
  if (targets.isEmpty) return false;
  final bool wide =
      MediaQuery.sizeOf(context).width >= kTagPickerWideBreakpoint;
  final Widget panel = TagPickerPanel(targets: targets, title: title);
  final bool? changed;
  if (wide) {
    changed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => FushiDialogFrame(
        maxWidth: 560,
        maxHeightFactor: 0.86,
        scrollable: false,
        child: panel,
      ),
    );
  } else {
    changed = await adaptiveModalSheet<bool>(
      context: context,
      builder: (BuildContext ctx) => panel,
    );
  }
  return changed ?? TagPickerPanel.lastChanged;
}

/// 一个打标签宿主（条目或合集），带写库分派。
@immutable
class _TagHost {
  const _TagHost.media(MediaRef this.media) : collectionId = null;
  const _TagHost.collection(int this.collectionId) : media = null;

  final MediaRef? media;
  final int? collectionId;

  String get key => media?.compositeKey ?? 'collection|$collectionId';

  Future<List<BookTagRow>> tags(FushiDatabase db) {
    final int? cid = collectionId;
    if (cid != null) return db.getTagsForCollection(cid);
    return tagsForMediaRef(db, media!);
  }

  Future<void> add(FushiDatabase db, int tagId) =>
      addTagToHost(db, tagId, media: media, collectionId: collectionId);

  Future<void> remove(FushiDatabase db, int tagId) =>
      removeTagFromHost(db, tagId, media: media, collectionId: collectionId);

  @override
  bool operator ==(Object other) => other is _TagHost && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// 一个条目当前挂的标签：按 [MediaKind] 穷尽分派到各域的 typed 查询。
Future<List<BookTagRow>> tagsForMediaRef(FushiDatabase db, MediaRef media) {
  switch (media.kind) {
    case MediaKind.epub:
      return db.getTagsForBook(media.entryKey);
    case MediaKind.srt:
      return db.getTagsForSrtBook(media.entryKey);
    case MediaKind.video:
      return db.getTagsForVideoBook(media.entryKey);
    case MediaKind.game:
      return db.getTagsForGame(media.entryKey);
  }
}

/// 给一个宿主（[media] 或 [collectionId] 二选一）挂标签：按 [MediaKind] 穷尽分派到
/// 各域的 typed 方法（墓碑 / 同步时钟语义留在各自方法里）。
Future<void> addTagToHost(
  FushiDatabase db,
  int tagId, {
  MediaRef? media,
  int? collectionId,
}) {
  assert((media != null) ^ (collectionId != null));
  if (collectionId != null) return db.addTagToCollection(collectionId, tagId);
  final MediaRef m = media!;
  switch (m.kind) {
    case MediaKind.epub:
      return db.addTagToBook(m.entryKey, tagId);
    case MediaKind.srt:
      return db.addTagToSrtBook(m.entryKey, tagId);
    case MediaKind.video:
      return db.addTagToVideoBook(m.entryKey, tagId);
    case MediaKind.game:
      return db.addTagToGame(m.entryKey, tagId);
  }
}

/// [addTagToHost] 的反操作。
Future<void> removeTagFromHost(
  FushiDatabase db,
  int tagId, {
  MediaRef? media,
  int? collectionId,
}) {
  assert((media != null) ^ (collectionId != null));
  if (collectionId != null) {
    return db.removeTagFromCollection(collectionId, tagId);
  }
  final MediaRef m = media!;
  switch (m.kind) {
    case MediaKind.epub:
      return db.removeTagFromBook(m.entryKey, tagId);
    case MediaKind.srt:
      return db.removeTagFromSrtBook(m.entryKey, tagId);
    case MediaKind.video:
      return db.removeTagFromVideoBook(m.entryKey, tagId);
    case MediaKind.game:
      return db.removeTagFromGame(m.entryKey, tagId);
  }
}

/// 合集成员 → 打标签用的 [MediaRef]。v83 起 epub 成员行 entryKey 是 uid，而标签映射
/// 键是 bookKey：经 `resolveEpubBookKeyByUid` 换算，反查不上（透传行 / 旧值）沿用原值。
/// 未知种类（对端新种类透传行）跳过。
Future<List<MediaRef>> tagRefsForCollectionMembers(
  FushiDatabase db,
  Iterable<int> collectionIds,
) async {
  final List<MediaRef> refs = <MediaRef>[];
  for (final int id in collectionIds) {
    for (final MediaCollectionItemRow row in await db.getCollectionItems(id)) {
      final MediaRef? ref = await tagRefForCollectionMember(db, row);
      if (ref != null) refs.add(ref);
    }
  }
  return refs;
}

/// 单个合集成员行 → 打标签用的 [MediaRef]（见 [tagRefsForCollectionMembers]）。
Future<MediaRef?> tagRefForCollectionMember(
  FushiDatabase db,
  MediaCollectionItemRow row,
) async {
  final MediaRef? ref = MediaRef.tryParse(row.mediaType, row.entryKey);
  if (ref == null) return null;
  if (ref.kind != MediaKind.epub) return ref;
  final String bookKey =
      await db.resolveEpubBookKeyByUid(row.entryKey) ?? row.entryKey;
  return MediaRef(kind: MediaKind.epub, entryKey: bookKey);
}

/// 选择器主体（sheet / 弹层 / 整页三种外壳共用）。
class TagPickerPanel extends ConsumerStatefulWidget {
  const TagPickerPanel({
    required this.targets,
    super.key,
    this.title,
    this.embedded = false,
  });

  final TagTargets targets;
  final String? title;

  /// true = 嵌在整页（[TagPickerPage]）里：没有底部关闭 / 应用以外的外壳语义，
  /// 关闭由页面返回键负责。
  final bool embedded;

  /// 单目标即时落库模式下，被外部手势（下拉 / 点遮罩）关掉时 pop 不带结果；
  /// 这里记最近一次面板是否落过库，供 [showTagPicker] 兜底返回。
  static bool lastChanged = false;

  @override
  ConsumerState<TagPickerPanel> createState() => TagPickerPanelState();
}

@visibleForTesting
class TagPickerPanelState extends ConsumerState<TagPickerPanel> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  TagCollectionScope _scope = TagCollectionScope.collection;

  List<BookTagRow>? _allTags;
  List<_TagHost> _hosts = const <_TagHost>[];

  /// 宿主现状：tagId → 带它的宿主数。
  Map<int, int> _initialCounts = const <int, int>{};

  /// 多目标模式下用户改过的意图（只会是 all / none）。
  final Map<int, TagCheckState> _intents = <int, TagCheckState>{};

  /// 单目标模式的当前已选集（即时落库）。
  final Set<int> _selected = <int>{};
  bool _changed = false;
  bool _applying = false;

  FushiDatabase get _db => ref.read(appProvider).database;

  bool get _hasCollections => widget.targets.collectionIds.isNotEmpty;

  /// 单目标 = 恰好一个宿主（含「合集本身」模式下的单个合集）。
  bool get _single => _hosts.length == 1;

  @override
  void initState() {
    super.initState();
    TagPickerPanel.lastChanged = false;
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<List<_TagHost>> _resolveHosts() async {
    final Set<_TagHost> hosts = <_TagHost>{
      for (final MediaRef m in widget.targets.media) _TagHost.media(m),
    };
    if (_scope == TagCollectionScope.collection) {
      hosts.addAll(<_TagHost>[
        for (final int id in widget.targets.collectionIds)
          _TagHost.collection(id),
      ]);
    } else {
      for (final MediaRef m in await tagRefsForCollectionMembers(
        _db,
        widget.targets.collectionIds,
      )) {
        hosts.add(_TagHost.media(m));
      }
    }
    return hosts.toList();
  }

  Future<void> _load() async {
    final FushiDatabase db = _db;
    final List<BookTagRow> all = await db.getAllTags();
    final List<_TagHost> hosts = await _resolveHosts();
    final Map<int, int> counts = <int, int>{};
    for (final _TagHost h in hosts) {
      for (final BookTagRow tag in await h.tags(db)) {
        counts[tag.id] = (counts[tag.id] ?? 0) + 1;
      }
    }
    if (!mounted) return;
    setState(() {
      _allTags = all;
      _hosts = hosts;
      _initialCounts = counts;
      _intents.clear();
      _selected
        ..clear()
        ..addAll(<int>[
          for (final MapEntry<int, int> e in counts.entries)
            if (hosts.isNotEmpty && e.value >= hosts.length) e.key,
        ]);
    });
  }

  TagCheckState _initialState(int tagId) {
    final int n = _initialCounts[tagId] ?? 0;
    if (n == 0 || _hosts.isEmpty) return TagCheckState.none;
    return n >= _hosts.length ? TagCheckState.all : TagCheckState.partial;
  }

  /// 标签在面板里当前显示的状态。
  @visibleForTesting
  TagCheckState stateOf(int tagId) {
    if (_single) {
      return _selected.contains(tagId) ? TagCheckState.all : TagCheckState.none;
    }
    return _intents[tagId] ?? _initialState(tagId);
  }

  Future<void> _toggle(BookTagRow tag) async {
    if (_hosts.isEmpty) return;
    if (_single) {
      final bool on = !_selected.contains(tag.id);
      setState(() => on ? _selected.add(tag.id) : _selected.remove(tag.id));
      final _TagHost host = _hosts.single;
      if (on) {
        await host.add(_db, tag.id);
      } else {
        await host.remove(_db, tag.id);
      }
      _markChanged();
      return;
    }
    // 多目标：原状（若是部分）→ 全加 → 全去 → 回到原状。
    final TagCheckState initial = _initialState(tag.id);
    final TagCheckState current = stateOf(tag.id);
    final TagCheckState next = switch (current) {
      TagCheckState.partial => TagCheckState.all,
      TagCheckState.all => TagCheckState.none,
      TagCheckState.none => initial == TagCheckState.partial
          ? TagCheckState.partial
          : TagCheckState.all,
    };
    setState(() {
      if (next == initial) {
        _intents.remove(tag.id);
      } else {
        _intents[tag.id] = next;
      }
    });
  }

  void _markChanged() {
    _changed = true;
    TagPickerPanel.lastChanged = true;
  }

  Future<void> _apply() async {
    if (_applying) return;
    setState(() => _applying = true);
    final FushiDatabase db = _db;
    final List<String> messages = <String>[];
    for (final MapEntry<int, TagCheckState> e in _intents.entries) {
      final BookTagRow? tag =
          _allTags?.where((BookTagRow t) => t.id == e.key).firstOrNull;
      int touched = 0;
      for (final _TagHost host in _hosts) {
        final bool has =
            (await host.tags(db)).any((BookTagRow t) => t.id == e.key);
        if (e.value == TagCheckState.all && !has) {
          await host.add(db, e.key);
          touched++;
        } else if (e.value == TagCheckState.none && has) {
          await host.remove(db, e.key);
          touched++;
        }
      }
      if (tag != null && touched > 0) {
        messages.add(
          e.value == TagCheckState.all
              ? t.batch_tag_added(name: tag.name, n: touched)
              : t.batch_tag_removed(name: tag.name, n: touched),
        );
      }
    }
    if (messages.isNotEmpty) _markChanged();
    if (!mounted) return;
    for (final String m in messages) {
      FushiToast.show(msg: m, severity: ToastSeverity.success);
    }
    Navigator.of(context).pop(_changed);
  }

  /// 新建标签（[name] 非空 = 搜索框一键新建；否则弹 [TagEditDialog] 选色）。
  Future<void> _create({String? name}) async {
    final List<BookTagRow> all = _allTags ?? const <BookTagRow>[];
    final int color = kTagPresetColors[all.length % kTagPresetColors.length];
    TagEditResult? result;
    if (name != null && name.trim().isNotEmpty) {
      result = TagEditResult(name: name.trim(), color: color);
    } else {
      result = await showAppDialog<TagEditResult>(
        context: context,
        builder: (_) => TagEditDialog(
          title: t.tag_new,
          initialName: _search.text.trim(),
          initialColor: color,
        ),
      );
    }
    if (result == null || !mounted) return;
    final int id;
    try {
      id = await _db.createTag(result.name, result.color);
    } on SqliteException catch (e) {
      if (e.extendedResultCode == 2067 && mounted) {
        FushiToast.show(
            msg: t.tag_name_duplicate, severity: ToastSeverity.warning);
        return;
      }
      rethrow;
    }
    _markChanged();
    final List<BookTagRow> refreshed = await _db.getAllTags();
    if (!mounted) return;
    setState(() {
      _allTags = refreshed;
      _search.clear();
    });
    final BookTagRow? created =
        refreshed.where((BookTagRow t) => t.id == id).firstOrNull;
    if (created != null) await _toggle(created);
  }

  Future<void> _setScope(TagCollectionScope scope) async {
    if (scope == _scope) return;
    setState(() {
      _scope = scope;
      _allTags = null;
    });
    await _load();
  }

  String _summary() {
    final List<String> parts = <String>[];
    final int items = widget.targets.media.length;
    final int collections = widget.targets.collectionIds.length;
    if (items > 0) parts.add(t.tag_picker_target_items(n: items));
    if (collections > 0) {
      parts.add(t.tag_picker_target_collections(n: collections));
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<BookTagRow>? all = _allTags;
    final bool wide =
        MediaQuery.sizeOf(context).width >= kTagPickerWideBreakpoint;
    final String query = _search.text;
    final List<BookTagRow> visible = all == null
        ? const <BookTagRow>[]
        : filterByMediaSearch<BookTagRow>(
            all,
            query,
            (BookTagRow tag) => <String>[tag.name],
          );
    final bool exact = all != null &&
        all.any((BookTagRow tag) =>
            normalizeMediaSearchText(tag.name) ==
            normalizeMediaSearchText(query));
    final List<BookTagRow> selected = all == null
        ? const <BookTagRow>[]
        : <BookTagRow>[
            for (final BookTagRow tag in all)
              if (stateOf(tag.id) != TagCheckState.none) tag,
          ];

    final Widget body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_hasCollections) ...<Widget>[
          _ScopeSelector(
            scope: _scope,
            onChanged: _setScope,
          ),
          SizedBox(height: tokens.spacing.gap),
        ],
        FushiSearchField(
          fieldKey: const ValueKey<String>('tag_picker_search'),
          controller: _search,
          focusNode: _searchFocus,
          hintText: t.tag_picker_search_hint,
          onChanged: (_) => setState(() {}),
          onSubmitted: (String value) {
            if (value.trim().isNotEmpty && !exact) _create(name: value);
          },
          onClear: () => setState(_search.clear),
        ),
        SizedBox(height: tokens.spacing.gap * 1.5),
        AnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          curve: FushiMotion.enter,
          alignment: Alignment.topCenter,
          child: selected.isEmpty
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: EdgeInsets.only(bottom: tokens.spacing.gap * 1.5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _SectionLabel(
                        text:
                            '${t.tag_picker_selected_label} · ${selected.length}',
                      ),
                      SizedBox(height: tokens.spacing.gap),
                      Wrap(
                        spacing: tokens.spacing.gap,
                        runSpacing: tokens.spacing.gap,
                        children: <Widget>[
                          for (final BookTagRow tag in selected)
                            FushiTagInputChip(
                              key: ValueKey<String>(
                                  'tag_picker_selected_${tag.id}'),
                              label: stateOf(tag.id) == TagCheckState.partial
                                  ? '${tag.name} · ${t.tag_picker_partial_state}'
                                  : tag.name,
                              color: Color(tag.colorValue),
                              onDeleted: () => _deselect(tag),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
        _SectionLabel(text: t.tag_picker_all_label),
        SizedBox(height: tokens.spacing.gap),
        if (all == null)
          Padding(
            padding: EdgeInsets.all(tokens.spacing.card),
            child: Center(child: adaptiveIndicator(context: context)),
          )
        else if (all.isEmpty && query.trim().isEmpty)
          FushiPlaceholderMessage(
            icon: FushiIcons.tag,
            message: t.tag_no_tags_hint,
          )
        else
          FushiEntranceScope(
            child: Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                for (int i = 0; i < visible.length; i++)
                  FushiStaggeredEntrance(
                    index: i,
                    child: FushiTagToggleChip(
                      key: ValueKey<String>('tag_picker_chip_${visible[i].id}'),
                      label: visible[i].name,
                      color: Color(visible[i].colorValue),
                      state: stateOf(visible[i].id),
                      onTap: () => _toggle(visible[i]),
                    ),
                  ),
                if (query.trim().isNotEmpty && !exact)
                  _CreateChip(
                    key: const ValueKey<String>('tag_picker_create'),
                    label: t.tag_picker_create_named(name: query.trim()),
                    onTap: () => _create(name: query),
                  ),
              ],
            ),
          ),
        if (all != null && visible.isEmpty && query.trim().isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: tokens.spacing.gap),
            child: Text(t.tag_picker_no_match, style: tokens.type.listSubtitle),
          ),
      ],
    );

    final Widget footer = Row(
      children: <Widget>[
        FushiTextButton(
          key: const ValueKey<String>('tag_picker_new'),
          onPressed: () => _create(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const FushiIcon(FushiIcons.add, size: 18),
              SizedBox(width: tokens.spacing.gap / 2),
              Text(t.tag_new),
            ],
          ),
        ),
        const Spacer(),
        if (widget.embedded)
          const SizedBox.shrink()
        else if (_single)
          FushiFilledButton(
            key: const ValueKey<String>('tag_picker_done'),
            onPressed: () => Navigator.of(context).pop(_changed),
            child: Text(t.dialog_done),
          )
        else ...<Widget>[
          adaptiveDialogAction(
            context: context,
            onPressed: () => Navigator.of(context).pop(_changed),
            child: Text(t.dialog_cancel),
          ),
          SizedBox(width: tokens.spacing.gap),
          FushiFilledButton(
            key: const ValueKey<String>('tag_picker_apply'),
            onPressed: _intents.isEmpty || _applying ? null : _apply,
            child: Text(t.batch_tag_apply),
          ),
        ],
      ],
    );

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              if (!widget.embedded) Navigator.of(context).maybePop(_changed);
              return null;
            },
          ),
        },
        child: FocusTraversalGroup(
          child: FushiModalSheetFrame(
            title: widget.title ?? t.tag_label,
            subtitle: _summary(),
            leadingIcon: FushiIcons.tag,
            scrollable: true,
            maxHeightFactor: wide ? null : 0.9,
            bodyPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              0,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            footerPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.gap,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
            body: body,
            footer: footer,
          ),
        ),
      ),
    );
  }

  Future<void> _deselect(BookTagRow tag) async {
    if (_single) {
      if (_selected.contains(tag.id)) await _toggle(tag);
      return;
    }
    setState(() {
      if (_initialState(tag.id) == TagCheckState.none) {
        _intents.remove(tag.id);
      } else {
        _intents[tag.id] = TagCheckState.none;
      }
    });
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: FushiDesignTokens.of(context).type.sectionLabel);
  }
}

/// 「作用于：合集本身 / 合集内全部条目」二选一 + 一行说明。
class _ScopeSelector extends StatelessWidget {
  const _ScopeSelector({required this.scope, required this.onChanged});

  final TagCollectionScope scope;
  final ValueChanged<TagCollectionScope> onChanged;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final Widget hint = AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      child: Text(
        scope == TagCollectionScope.collection
            ? t.tag_picker_scope_collection_hint
            : t.tag_picker_scope_members_hint,
        key: ValueKey<TagCollectionScope>(scope),
        style: tokens.type.listSubtitle,
      ),
    );
    final Widget segmented = adaptiveSegmentedButton<TagCollectionScope>(
      context: context,
      segments: <ButtonSegment<TagCollectionScope>>[
        ButtonSegment<TagCollectionScope>(
          value: TagCollectionScope.collection,
          icon: const FushiIcon(FushiIcons.collection, size: 18),
          label: Text(
            t.tag_picker_scope_collection,
            key: const ValueKey<String>('tag_picker_scope_collection'),
          ),
        ),
        ButtonSegment<TagCollectionScope>(
          value: TagCollectionScope.members,
          icon: const FushiIcon(FushiIcons.dictionary, size: 18),
          label: Text(
            t.tag_picker_scope_members,
            key: const ValueKey<String>('tag_picker_scope_members'),
          ),
        ),
      ],
      selected: <TagCollectionScope>{scope},
      onSelectionChanged: (Set<TagCollectionScope> v) {
        if (v.isNotEmpty) onChanged(v.first);
      },
    );
    final Widget column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(t.tag_picker_scope_label, style: tokens.type.sectionLabel),
        SizedBox(height: tokens.spacing.gap),
        segmented,
        SizedBox(height: tokens.spacing.gap),
        hint,
      ],
    );
    if (apple || isEinkTheme(context)) return column;
    // M3E：饱和的 secondaryContainer 色块分区，把「作用范围」和标签云分开。
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.gap * 1.5),
        child: column,
      ),
    );
  }
}

/// 搜索无果时的「新建“xxx”」chip（M3E tertiary 色块）。
class _CreateChip extends StatelessWidget {
  const _CreateChip({required this.label, required this.onTap, super.key});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return FushiTagChip(label: '+ $label', onTap: onTap);
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final Color fill = eink ? scheme.surface : scheme.tertiaryContainer;
    final Color fg = eink ? scheme.onSurface : scheme.onTertiaryContainer;
    const OutlinedBorder shape = StadiumBorder();
    return FushiPressScale(
      scale: 0.94,
      child: Material(
        color: fill,
        shape: eink
            ? StadiumBorder(side: BorderSide(color: scheme.outline))
            : shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  FushiIcon(FushiIcons.add, size: 18, color: fg),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: (Theme.of(context).textTheme.labelLarge ??
                              const TextStyle())
                          .copyWith(color: fg, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
