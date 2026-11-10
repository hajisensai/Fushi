/// 复习卡片浏览（spec `docs/specs/2026-11-04-srs-browser-redesign.md`，手机与桌面通用）：
///
/// - 搜索：搜索框 + 积木（[SrsBrowseQueryBar]）。积木只是 Anki 搜索语法顶层「且」链的结构化视图，语法串是唯一
///   真相（[srsParseBrowseChips] / [srsBrowseChipsToQuery]）；拆不动的整段留成语法积木。打字只改草稿（实时筛），
///   回车 / 粘贴整段才拆成积木；点积木改取值 / 包含排除（实时「将筛出 N 张」）。语法见 [srsBrowseSearchHelpRows]；
///   不记语法也可以「搜索范围」选一个字段 + 关键字。
/// - 快捷视图（今天到期 / 最近添加 / 难卡 / 问题卡 / 已暂停，带计数）+ 用户保存的视图（存 profile 偏好，
///   不进复习同步）；计数一次 `browse_counts` 算完。
/// - 三种视图：卡片列表（默认，富卡片行；手机左滑暂停 / 旗标）、表格（宽屏：选列 / 排列、表头排序、双击原地改、
///   分组）、出处（按作品分组，「只看这一作」）。
/// - 检查器：宽屏右栏，手机全屏详情页（[SrsBrowseDetailPage]）；预览 / 编辑（停笔自动保存，进撤销栈）/ 历史
///   （FSRS 保持率曲线 + 逐次评分）。宽屏另有健康条（问题卡 / 难卡 / 疑似重复，一键修复可撤销）。
/// - 排序：排序字段 / 指定字段 / 到期 / 新建 / 修改 / 间隔 / 难度 / 保持率 / 复习次数 / 遗忘次数 / 牌组 /
///   笔记类型，升降序可切；卡片模式（一行一张卡）与笔记模式（一行一条笔记）可切。
/// - 批量：长按 / 「选择」进入多选，桌面 Ctrl / Shift 点选；暂停、搁置、旗标、改牌组、加删标签、
///   重置为新卡、设置到期日、删除笔记（确认），以及外部提供的「更改笔记类型」。每个批量操作一个
///   事件批次落库（可同步），并进本页的撤销栈（Ctrl+Z / 撤销按钮）。
///
/// 键盘（本页焦点作用域；文本框持焦时一概不拦）：↑ / ↓ 移动当前行（Shift 扩选），
/// Enter = 预览（宽屏翻面），Ctrl+A 全选，Esc 取消选择，Delete 删除所选，Ctrl+Z 撤销，
/// Ctrl+F 搜索。裸空格不在列表上用——确认一律 Enter（`global_navigation.dart` 的裸空格中和）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_browse_ops.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_batch_edit.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/page_focus_ownership.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_card_tile.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_dialogs.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_inspector.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_preview.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_query.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_query_bar.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_saved_views.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_views.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/pages/implementations/srs/srs_load_error.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/srs/srs_navigation.dart';

/// 「更改笔记类型」的入口（由别的模块提供）：传入要改的笔记 ID。
typedef SrsChangeNoteTypeFlow =
    Future<void> Function(BuildContext context, List<String> noteIds);

/// 宽屏分栏（列表 + 检查器）的最小宽度。
const double kSrsBrowseSplitMinWidth = 840;

/// 一次重算的结果：结果（null = 查询不合法）+ 搜索错误 + 字段下拉的选项，以及选中项 / 当前行 / 锚点
/// 在新结果里还剩的部分（行号由原生会话按 id 查出）。
typedef _QueryResult = ({
  SrsBrowseResult? result,
  String? error,
  List<String> fieldNames,
  List<SrsNoteTypeView> noteTypes,
  Set<String> selected,
  String? currentId,
  int currentAt,
  String? anchorId,
  int anchorAt,
});

/// 本页撤销栈的一步（会话级，不同步——与复习页同一约定）。
class _UndoEntry {
  const _UndoEntry(this.revert);
  final SrsBatchRevert revert;
}

/// 结果区的三种视图（表格只在宽屏）。
enum _SrsBrowseLayout { list, table, sources }

class SrsBrowsePage extends ConsumerStatefulWidget {
  const SrsBrowsePage({
    super.key,
    this.initialQuery,
    this.initialCardId,
    this.onChangeNoteType,
    this.onMigrateToFushiCard,
  });

  /// 打开时带上的查询（AnkiConnect guiBrowse）。
  final String? initialQuery;

  /// 打开时定位到的卡片（复习页顶栏「浏览」：像 Anki 一样直接落在正在复习的这张卡上，
  /// 预览 / 编辑就在旁边）。不在当前查询结果里时按默认落到第一行。
  final String? initialCardId;

  /// 批量菜单的「更改笔记类型」；null = 不显示这一项。
  final SrsChangeNoteTypeFlow? onChangeNoteType;

  /// 批量菜单的「迁移到 Fushi 卡片」（只对 Lapis 笔记）；null = 不显示这一项。
  final SrsChangeNoteTypeFlow? onMigrateToFushiCard;

  @override
  ConsumerState<SrsBrowsePage> createState() => _SrsBrowsePageState();
}

class _SrsBrowsePageState extends ConsumerState<SrsBrowsePage> {
  /// 已拆成积木的条件（查询的顶层「且」链）。
  late List<SrsBrowseChip> _chips = srsParseBrowseChips(
    widget.initialQuery ?? '',
  );

  /// 还没拆成积木的草稿（打字实时筛）。
  final TextEditingController _draft = TextEditingController();
  String _lastDraft = '';
  final FocusNode _queryFocus = FocusNode(debugLabel: 'srs-browse-search');
  final FocusNode _focusNode = FocusNode(debugLabel: 'srs-browse');

  /// 预览卡面的查词弹窗（开着时 Enter / 方向键不翻面、不换卡）。
  final SrsCardLookupController _previewLookup = SrsCardLookupController();
  late final PageFocusOwnership _focusOwnership = PageFocusOwnership(
    node: _focusNode,
    canOwn: (FocusReclaimCause cause) =>
        mounted &&
        (ModalRoute.of(context)?.isCurrent ?? false) &&
        !_editingText,
  );
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;

  bool _loading = true;
  bool _canSchedule = true;

  /// 最近一次重算失败的原因（库打不开 / 内核报错 / 结果连着两次被挤掉）。非 null 时列表区换成出错占位页 + 重试，
  /// 不再停在加载态（BUG：以前 [_refresh] 不收口异常，[_loading] 永远是 true，页面一直转圈）。
  Object? _loadError;

  /// 原生侧的常驻浏览会话（搜索语料与列数据在 Rust 里，随写入增量更新；本页只取可见行）。
  SrsBrowseSession? _session;
  SrsBrowseResult? _result;
  List<String> _fieldNames = const <String>[];
  List<SrsNoteTypeView> _noteTypes = const <SrsNoteTypeView>[];
  List<String> _deckNames = const <String>[];
  List<String> _tags = const <String>[];
  String? _searchError;

  SrsBrowseMode _mode = SrsBrowseMode.cards;
  SrsBrowseSort _sort = const SrsBrowseSort();
  _SrsBrowseLayout _layout = _SrsBrowseLayout.list;
  List<SrsBrowseTableColumn> _columns = kSrsBrowseDefaultColumns;
  SrsBrowseTableGroup _group = SrsBrowseTableGroup.none;
  SrsBrowseInspectorTab _inspectorTab = SrsBrowseInspectorTab.preview;

  /// 快捷视图 / 保存的视图的计数（按视图 id）与健康条计数；随写入与牌组范围变化重算。
  Map<String, int> _viewCounts = const <String, int>{};
  SrsBrowseHealthCounts? _health;
  String? _countsKey;

  /// 用户保存的视图（profile 偏好）。
  List<SrsBrowseSavedView> _savedViews = const <SrsBrowseSavedView>[];

  /// 「搜索范围」：null = 全部字段（搜索框按 Anki 语法解析）；否则是字段名，搜索框是关键字。
  String? _searchField;

  /// 当前行（预览目标 / 键盘位置）的 ID；见 [_idOf]。
  late String? _currentId = widget.initialCardId;

  /// [_currentId] 在 [_result] 里的行号（-1 = 不在结果里）。
  int _currentAt = -1;

  /// 检查器上一次显示的行：换页 / 重查空档里取不到当前行时留着它，检查器（和卡面平台视图）不卸载。
  SrsBrowseRow? _shownRow;
  final Set<String> _selected = <String>{};
  bool _selectMode = false;
  String? _anchorId;
  int _anchorAt = -1;
  bool _showAnswer = false;
  int _revision = 0;

  /// 手机详情页据此重读（写入 / 撤销后递增，与 [_revision] 同步）。
  final ValueNotifier<int> _detailRevision = ValueNotifier<int>(0);
  bool _busy = false;
  final List<_UndoEntry> _undo = <_UndoEntry>[];

  @override
  void initState() {
    super.initState();
    _savedViews = decodeSrsBrowseSavedViews(_readSavedViewsPref());
    _columns = decodeSrsBrowseColumns(
      ref.read(appProvider).srsBrowseTableColumns,
    );
    unawaited(_refresh());
  }

  @override
  void dispose() {
    // 原生侧的会话（字段文本可达几百 MB）随页面关掉释放。
    final SrsBrowseSession? session = _session;
    if (session != null) srsRunLogged('SrsBrowse.close', session.close);
    _debounce?.cancel();
    _draft.dispose();
    _queryFocus.dispose();
    _focusNode.dispose();
    _scroll.dispose();
    _previewLookup.dispose();
    _detailRevision.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 数据

  bool get _editingText =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>() !=
      null;

  bool get _selecting => _selectMode || _selected.isNotEmpty;

  int get _length => _result?.length ?? 0;

  int get _currentIndex => _currentId == null ? -1 : _currentAt;

  /// 有批量操作的目标（选中项，或当前行）。
  bool get _hasTargets => _selected.isNotEmpty || _currentIndex >= 0;

  /// 草稿那一段（有搜索范围时按「该字段包含关键字」）。
  String get _draftQuery {
    final String? field = _searchField;
    return field == null
        ? _draft.text
        : srsFieldContainsQuery(field, _draft.text);
  }

  String get _effectiveQuery => <String>[
    srsBrowseChipsToQuery(_chips),
    _draftQuery,
  ].where((String s) => s.trim().isNotEmpty).join(' ');

  /// 分组生效时按分组键排（表格），否则用户的排序。
  SrsBrowseSort get _effectiveSort =>
      (_layout == _SrsBrowseLayout.table ? srsBrowseGroupSort(_group) : null) ??
      _sort;

  _SrsBrowseLayout _layoutFor(bool wide) =>
      !wide && _layout == _SrsBrowseLayout.table
      ? _SrsBrowseLayout.list
      : _layout;

  /// 内置 Fushi 卡片类型的名字（问题卡的「缺音频」只判它）；库里没有这个类型 null。
  String? get _fushiNoteTypeName => _noteTypes
      .where((SrsNoteTypeView n) => n.builtinKey == kSrsBuiltinFushiCardKey)
      .firstOrNull
      ?.name;

  /// 每次重算的序号：慢的旧查询算完时若已有新查询，结果作废。
  int _queryGeneration = 0;

  /// 按当前查询 / 排序 / 模式重算（原生会话先按 id 重读写过的行，不整份重读）。[reuse]：条件没变且之后没有
  /// 写入时原生侧直接给回上次的结果（预览返回之类不写库的刷新，零重算）。
  Future<void> _refresh({bool reuse = false}) async {
    final int generation = ++_queryGeneration;
    final bool first = _result == null && _loading;
    final SrsDbStore store;
    final _QueryResult result;
    final SrsBrowseSession session;
    try {
      final SrsDbStore? opened = await ref.read(srsStoreProvider.future);
      if (!mounted || generation != _queryGeneration) return;
      if (opened == null) {
        // 复习模块没开 / 库不可用：明说，不停在加载态。
        setState(() {
          _loading = false;
          _loadError = t.srs_engine_unavailable;
        });
        return;
      }
      store = opened;
      SrsBrowseSession? s = _session;
      if (s == null || !identical(s.store, store)) {
        // 换了库（profile 切换 / 库重开）：旧会话注销，按新库开一份。
        if (s != null) srsRunLogged('SrsBrowse.close', s.close);
        s = _session = SrsBrowseSession(store);
      }
      session = s;
      result = await _compute(session, reuse: reuse);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsBrowse.refresh', e, stack);
      if (!mounted || generation != _queryGeneration) return;
      setState(() {
        _loading = false;
        _loadError = e;
      });
      return;
    }
    if (!mounted || generation != _queryGeneration) return;
    setState(() {
      _canSchedule = store.canSchedule;
      _loading = false;
      _loadError = null;
      _apply(result);
    });
    unawaited(_refreshMeta(session, first: first));
    // 带着 initialCardId 打开：列表首次出现后把这一行滚进视口。
    if (first && widget.initialCardId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final int i = _currentIndex;
        if (i >= 0) _scrollToIndex(i);
      });
    }
  }

  /// 积木补全 / 面板用的牌组名与标签，以及快捷视图 / 保存的视图 / 健康条的计数（一次 `browse_counts`）。
  /// 只在首次、写入后或牌组范围 / 模式变了时重算（打字不重算）。失败只记日志：计数是辅助信息。
  Future<void> _refreshMeta(
    SrsBrowseSession session, {
    required bool first,
  }) async {
    final List<SrsBrowseChip> scope = <SrsBrowseChip>[
      for (final SrsBrowseChip c in _chips)
        if (c.kind == SrsBrowseChipKind.deck) c,
    ];
    final String key =
        '$_revision|${_mode.name}|${srsBrowseChipsToQuery(scope)}|'
        '${encodeSrsBrowseSavedViews(_savedViews)}';
    if (key == _countsKey) return;
    _countsKey = key;
    try {
      if (first || _deckNames.isEmpty) {
        final List<SrsDeckSummary> decks = await session.store.deckSummaries();
        // 标签走浏览会话同一份语料（不另开会话、不登记持有者）。
        final List<String> tags = <String>[
          for (final Object? v
              in (await session.store.browseCommand(<String, Object?>{
                    'op': 'anki_tags',
                  })).map['tags']!
                  as List<Object?>)
            v! as String,
        ];
        if (!mounted) return;
        setState(() {
          _deckNames = <String>[
            for (final SrsDeckSummary d in decks) d.fullName,
          ];
          _tags = tags;
        });
      }
      final String? fushi = _fushiNoteTypeName;
      final List<(String, String)> queries = <(String, String)>[
        for (final SrsBrowseQuickView v in SrsBrowseQuickView.values)
          (
            v.name,
            srsBrowseChipsToQuery(
              srsBrowseToggleQuickView(
                scope,
                srsParseBrowseChips(
                  srsBrowseQuickViewQuery(v, fushiNoteTypeName: fushi),
                ),
              ),
            ),
          ),
        for (int i = 0; i < _savedViews.length; i++)
          ('saved-$i', _savedViews[i].query),
      ];
      // 健康条四项一律按笔记数（文案也写「N 条笔记」），不随列表的卡片 / 笔记模式变：
      // 多卡笔记不会被数成好几份。健康条只把条件套到列表上，不做写入。
      final List<(String, String)> noteQueries = <(String, String)>[
        ('health-empty', kSrsBrowseHealthEmptyQuery),
        if (fushi != null) ('health-audio', srsBrowseMissingAudioQuery(fushi)),
        ('health-hard', kSrsBrowseHealthHardQuery),
        ('health-dupes', kSrsBrowseHealthDupesQuery),
      ];
      final List<int> counts = await session.counts(<String>[
        for (final (String, String) q in queries) q.$2,
      ], mode: _mode);
      final List<int> noteCounts = await session.counts(<String>[
        for (final (String, String) q in noteQueries) q.$2,
      ], mode: SrsBrowseMode.notes);
      if (!mounted || key != _countsKey) return;
      final Map<String, int> byId = <String, int>{
        for (int i = 0; i < queries.length; i++) queries[i].$1: counts[i],
        for (int i = 0; i < noteQueries.length; i++)
          noteQueries[i].$1: noteCounts[i],
      };
      setState(() {
        _viewCounts = byId;
        _health = SrsBrowseHealthCounts(
          emptyField: byId['health-empty'] ?? -1,
          missingAudio: byId['health-audio'] ?? -1,
          hard: byId['health-hard'] ?? -1,
          dupes: byId['health-dupes'] ?? -1,
        );
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsBrowse.meta', e, stack);
      _countsKey = null;
    }
  }

  /// 出错占位页的「重试」：回到加载态再重算一次（库没打开的话连库一起重开）。
  void _retryLoad() {
    final bool storeFailed = _session == null;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    if (storeFailed) ref.invalidate(srsStoreProvider);
    unawaited(_refresh());
  }

  /// 按当前查询 / 排序 / 模式在原生会话上查（筛选、排序都在 Rust 里），再查出选中项 / 当前行 / 锚点在新结果里的
  /// 行号，取好首屏与当前行那一页。查询不合法 / 不支持时给出原因、列表为空。
  ///
  /// 刚查出的结果在取行号 / 首屏之前被挤掉（[SrsBrowseResultGone]：控制通道等别的持有者在同一个原生会话上连查了
  /// 好几次，或会话被释放）时，按同样条件重查**一次**——重查会让原生侧重建会话与结果；连着两次都被挤掉说明不是
  /// 偶发竞争，异常交给 [_refresh] 转出错状态，而不是无限递归重查（以前这里递归没有上限）。
  Future<_QueryResult> _compute(
    SrsBrowseSession session, {
    required bool reuse,
  }) async {
    try {
      return await _computeOnce(session, reuse: reuse);
    } on SrsBrowseResultGone catch (e, stack) {
      ErrorLogService.instance.log('SrsBrowse.resultGone', e, stack);
      return _computeOnce(session, reuse: false);
    }
  }

  Future<_QueryResult> _computeOnce(
    SrsBrowseSession session, {
    required bool reuse,
  }) async {
    final List<SrsNoteTypeView> noteTypes = await session.store.noteTypes();
    final List<String> fieldNames = srsBrowseFieldNames(noteTypes);
    final List<String> keep = _selected.toList();
    final String? current = _currentId;
    final String? anchor = _anchorId;
    try {
      final SrsBrowseResult r = await session.query(
        query: _effectiveQuery,
        sort: _effectiveSort,
        mode: _mode,
        reuse: reuse,
      );
      final List<int> at = await r.indicesOf(<String>[
        current ?? '',
        anchor ?? '',
        ...keep,
      ]);
      int currentAt = current == null ? -1 : at[0];
      String? currentId = currentAt < 0 ? null : current;
      final int anchorAt = anchor == null ? -1 : at[1];
      if (currentId == null && r.length > 0) {
        await r.ensure(0, 1);
        currentId = r.idOf(r.rowAt(0)!);
        currentAt = 0;
      }
      await r.ensure(0, kSrsBrowsePage);
      if (currentAt >= kSrsBrowsePage) await r.ensure(currentAt, currentAt + 1);
      return (
        result: r,
        error: null,
        fieldNames: fieldNames,
        noteTypes: noteTypes,
        selected: <String>{
          for (int i = 0; i < keep.length; i++)
            if (at[i + 2] >= 0) keep[i],
        },
        currentId: currentId,
        currentAt: currentAt,
        anchorId: anchorAt < 0 ? null : anchor,
        anchorAt: anchorAt,
      );
    } on SrsSearchUnsupported catch (e) {
      return (
        result: null,
        error: e.reason,
        fieldNames: fieldNames,
        noteTypes: noteTypes,
        selected: const <String>{},
        currentId: null,
        currentAt: -1,
        anchorId: null,
        anchorAt: -1,
      );
    }
  }

  /// 换上一次重算的结果（调用方负责 setState）。
  void _apply(_QueryResult result) {
    _result = result.result;
    _searchError = result.error;
    _fieldNames = result.fieldNames;
    _noteTypes = result.noteTypes;
    _selected
      ..clear()
      ..addAll(result.selected);
    _currentId = result.currentId;
    _currentAt = result.currentAt;
    _anchorId = result.anchorId;
    _anchorAt = result.anchorAt;
  }

  /// 按当前查询 / 排序 / 模式重算。
  void _requery() => unawaited(_refresh());

  /// 取第 [index] 行所在的那一页，取到后重画；结果已被换掉时重新查询。
  void _loadRow(SrsBrowseResult r, int index) {
    unawaited(
      r
          .ensure(index, index + 1)
          .then(
            (_) {
              if (mounted && identical(r, _result)) setState(() {});
            },
            onError: (Object e, StackTrace stack) {
              if (e is SrsBrowseResultGone) {
                if (mounted && identical(r, _result)) _requery();
                return;
              }
              ErrorLogService.instance.log('SrsBrowse.rows', e, stack);
            },
          ),
    );
  }

  /// 批量操作的目标：给了 [ids] 用它（左滑 / 检查器里对单张卡的动作），否则有选中项用选中项，再否则用当前行
  /// （原生会话按列表顺序展开成卡 / 笔记 id）。
  Future<SrsBrowseTargets?> _loadTargets({List<String>? ids}) async {
    final SrsBrowseResult? r = _result;
    final String? current = _currentIndex >= 0 ? _currentId : null;
    if (r == null) return null;
    final List<String> rowIds =
        ids ?? (_selected.isNotEmpty ? _selected.toList() : <String>[?current]);
    if (rowIds.isEmpty) return null;
    try {
      return await r.targets(rowIds);
    } on SrsBrowseResultGone {
      _requery();
      return null;
    }
  }

  // ------------------------------------------------------------------ 搜索积木 / 视图

  void _setChips(List<SrsBrowseChip> chips) {
    setState(() => _chips = chips);
    _requery();
  }

  void _onDraftChanged(String text) {
    final String before = _lastDraft;
    _lastDraft = text;
    // 粘贴整段（一次进来多个字、含空白、能拆出两块以上）：直接拆成积木。打字只改草稿。
    if (_searchField == null &&
        text.length - before.length > 1 &&
        text.contains(RegExp(r'\s'))) {
      final List<SrsBrowseChip> parsed = srsParseBrowseChips(text);
      if (parsed.length >= 2 &&
          parsed.every(
            (SrsBrowseChip c) => c.kind != SrsBrowseChipKind.syntax,
          )) {
        _draft.clear();
        _lastDraft = '';
        _setChips(<SrsBrowseChip>[..._chips, ...parsed]);
        return;
      }
    }
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) _requery();
    });
  }

  /// 回车：草稿并进积木（有搜索范围时整段是一块「字段包含」语法积木）。
  void _onDraftSubmitted(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      _requery();
      return;
    }
    final List<SrsBrowseChip> next = _searchField == null
        ? srsBrowseCommitDraft(_chips, text)
        : <SrsBrowseChip>[..._chips, SrsBrowseChip.syntax(_draftQuery)];
    _draft.clear();
    _lastDraft = '';
    setState(() => _searchField = null);
    _setChips(next);
  }

  List<SrsBrowseSuggestion> get _suggestions =>
      _searchField != null || !_queryFocus.hasFocus
      ? const <SrsBrowseSuggestion>[]
      : srsBrowseSuggestions(
          _draft.text,
          decks: _deckNames,
          tags: _tags,
          noteTypes: <String>[
            for (final SrsNoteTypeView n in _noteTypes) n.name,
          ],
          cardTypes: srsBrowseCardTypeNames(<List<String>>[
            for (final SrsNoteTypeView n in _noteTypes)
              <String>[for (final SrsTemplateDef p in n.templates) p.name],
          ]),
        );

  List<SrsBrowseChipOption> _optionsFor(SrsBrowseChipKind kind) =>
      switch (kind) {
        SrsBrowseChipKind.deck => <SrsBrowseChipOption>[
          for (final String d in _deckNames)
            SrsBrowseChipOption(
              value: srsBrowseLiteral(d),
              label: d.split('::').last,
              depth: '::'.allMatches(d).length,
            ),
        ],
        SrsBrowseChipKind.tag => <SrsBrowseChipOption>[
          for (final String tag in _tags)
            SrsBrowseChipOption(value: srsBrowseLiteral(tag), label: tag),
        ],
        SrsBrowseChipKind.noteType => <SrsBrowseChipOption>[
          for (final SrsNoteTypeView n in _noteTypes)
            SrsBrowseChipOption(value: srsBrowseLiteral(n.name), label: n.name),
        ],
        SrsBrowseChipKind.state => <SrsBrowseChipOption>[
          for (final String s in kSrsBrowseStates)
            SrsBrowseChipOption(value: s, label: srsBrowseStateLabel(s)),
        ],
        SrsBrowseChipKind.source => <SrsBrowseChipOption>[
          for (final String k in <String>[
            SrsSourceKind.book,
            SrsSourceKind.manga,
            SrsSourceKind.video,
            SrsSourceKind.audiobook,
            SrsSourceKind.game,
            SrsSourceKind.music,
            SrsSourceKind.web,
          ])
            SrsBrowseChipOption(value: k, label: srsBrowseSourceKindLabel(k)),
          SrsBrowseChipOption(value: 'none', label: t.srs_browse_source_none),
        ],
        _ => const <SrsBrowseChipOption>[],
      };

  /// 点积木：改取值 / 包含排除，「将筛出 N 张」按把这块换成候选后的整条查询实时算。
  Future<void> _editChip(int index) async {
    final SrsBrowseSession? session = _session;
    if (session == null || index >= _chips.length) return;
    final SrsBrowseChip chip = _chips[index];
    final SrsBrowseChipEdit? edit = await _focusOwnership.guardOverlay(
      () => showSrsBrowseChipEditor(
        context,
        chip: chip,
        options: _optionsFor(chip.kind),
        count: (SrsBrowseChip candidate) async {
          final String q = <String>[
            srsBrowseChipsToQuery(
              srsBrowseReplaceChip(_chips, index, candidate),
            ),
            _draftQuery,
          ].where((String s) => s.trim().isNotEmpty).join(' ');
          return (await session.counts(<String>[q], mode: _mode)).single;
        },
      ),
    );
    if (edit == null || !mounted) return;
    _setChips(
      srsBrowseReplaceChip(_chips, index, edit.removed ? null : edit.chip),
    );
  }

  Future<void> _pickField() async {
    final String? picked = await _focusOwnership.guardOverlay(
      () => pickSrsBrowseField(
        context,
        fieldNames: _fieldNames,
        selected: _searchField,
        title: t.srs_browse_search_field_label,
      ),
    );
    if (picked == null || !mounted) return;
    setState(
      () => _searchField = picked == kSrsBrowseAllFields ? null : picked,
    );
    _requery();
  }

  Future<void> _pickSort() async {
    final SrsBrowseSort? picked = await _focusOwnership.guardOverlay(
      () => pickSrsBrowseSort(context, current: _sort, fieldNames: _fieldNames),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _sort = picked;
      _group = SrsBrowseTableGroup.none;
    });
    _requery();
  }

  Future<void> _pickColumns() async {
    final List<SrsBrowseTableColumn>? picked = await _focusOwnership
        .guardOverlay(
          () => showSrsBrowseColumnsSheet(context, current: _columns),
        );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(
      () => _columns = decodeSrsBrowseColumns(encodeSrsBrowseColumns(picked)),
    );
    await ref
        .read(appProvider)
        .setSrsBrowseTableColumns(encodeSrsBrowseColumns(_columns));
  }

  Future<void> _pickGroup() async {
    final SrsBrowseTableGroup? picked = await _focusOwnership.guardOverlay(
      () => showFushiChoiceDialog<SrsBrowseTableGroup>(
        context: context,
        title: t.srs_browse_table_group,
        icon: FushiIcons.gridView,
        selected: _group,
        options: <FushiChoiceOption<SrsBrowseTableGroup>>[
          for (final SrsBrowseTableGroup g in SrsBrowseTableGroup.values)
            FushiChoiceOption<SrsBrowseTableGroup>(
              value: g,
              label: switch (g) {
                SrsBrowseTableGroup.none => t.srs_browse_table_group_none,
                SrsBrowseTableGroup.deck => t.srs_browse_table_group_deck,
                SrsBrowseTableGroup.source => t.srs_browse_table_group_source,
                SrsBrowseTableGroup.added => t.srs_browse_table_group_added,
              },
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _group = picked);
    _requery();
  }

  void _setLayout(_SrsBrowseLayout l) {
    if (l == _layout) return;
    final bool regroup =
        _group != SrsBrowseTableGroup.none &&
        (l == _SrsBrowseLayout.table || _layout == _SrsBrowseLayout.table);
    setState(() => _layout = l);
    if (regroup) _requery();
  }

  /// 套用一条视图条件（快捷视图 / 保存的视图 / 健康条 / 「只看这一作」）：留下牌组积木，其余换成它；
  /// 已经套着时再点 = 撤掉。
  void _applyView(String query) {
    _draft.clear();
    _lastDraft = '';
    _setChips(srsBrowseToggleQuickView(_chips, srsParseBrowseChips(query)));
  }

  List<SrsBrowseViewEntry> _viewEntries() {
    final String? fushi = _fushiNoteTypeName;
    int? count(String id) {
      final int? c = _viewCounts[id];
      return c == null || c < 0 ? null : c;
    }

    return <SrsBrowseViewEntry>[
      for (final SrsBrowseQuickView v in SrsBrowseQuickView.values)
        SrsBrowseViewEntry(
          id: v.name,
          label: srsBrowseQuickViewLabel(v),
          icon: srsBrowseQuickViewIcon(v),
          selected: srsBrowseChipsContain(
            _chips,
            srsParseBrowseChips(
              srsBrowseQuickViewQuery(v, fushiNoteTypeName: fushi),
            ),
          ),
          count: count(v.name),
          onTap: () =>
              _applyView(srsBrowseQuickViewQuery(v, fushiNoteTypeName: fushi)),
        ),
      for (int i = 0; i < _savedViews.length; i++)
        SrsBrowseViewEntry(
          id: 'saved-$i',
          label: _savedViews[i].name,
          icon: FushiIcons.bookmark,
          selected: srsBrowseChipsContain(
            _chips,
            srsParseBrowseChips(_savedViews[i].query),
          ),
          count: count('saved-$i'),
          onTap: () => _applyView(_savedViews[i].query),
          onMenu: () => srsRunLogged('SrsBrowse.viewMenu', () => _viewMenu(i)),
        ),
    ];
  }

  String _readSavedViewsPref() => ref.read(appProvider).srsBrowseSavedViews;

  Future<void> _writeSavedViews(List<SrsBrowseSavedView> views) async {
    setState(() => _savedViews = views);
    await ref
        .read(appProvider)
        .setSrsBrowseSavedViews(encodeSrsBrowseSavedViews(views));
    if (_session != null) unawaited(_refreshMeta(_session!, first: false));
  }

  Future<void> _saveView() async {
    final String query = _effectiveQuery.trim();
    if (query.isEmpty) return;
    final String? name = await _focusOwnership.guardOverlay(
      () => askSrsBrowseViewName(context, title: t.srs_browse_view_save),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    await _writeSavedViews(<SrsBrowseSavedView>[
      ..._savedViews,
      SrsBrowseSavedView(name: name.trim(), query: query),
    ]);
    FushiToast.show(msg: t.srs_browse_view_saved);
  }

  Future<void> _viewMenu(int index) async {
    final int? action = await _focusOwnership.guardOverlay(
      () => showFushiChoiceDialog<int>(
        context: context,
        title: _savedViews[index].name,
        icon: FushiIcons.bookmark,
        options: <FushiChoiceOption<int>>[
          FushiChoiceOption<int>(
            value: 0,
            label: t.srs_browse_view_rename,
            icon: FushiIcons.edit,
          ),
          FushiChoiceOption<int>(
            value: 1,
            label: t.srs_browse_view_delete,
            icon: FushiIcons.delete,
          ),
        ],
      ),
    );
    if (action == null || !mounted) return;
    final List<SrsBrowseSavedView> views = <SrsBrowseSavedView>[..._savedViews];
    if (action == 1) {
      views.removeAt(index);
    } else {
      final String? name = await _focusOwnership.guardOverlay(
        () => askSrsBrowseViewName(
          context,
          title: t.srs_browse_view_rename,
          initial: views[index].name,
        ),
      );
      if (name == null || name.trim().isEmpty || !mounted) return;
      views[index] = SrsBrowseSavedView(
        name: name.trim(),
        query: views[index].query,
      );
    }
    await _writeSavedViews(views);
  }

  // ------------------------------------------------------------------ 原地编辑

  /// 检查器 / 表格里改一个字段：条件写（计划之后又被改过的不覆盖）+ 进撤销栈。
  Future<void> _saveField(String noteId, String fieldName, String value) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null || !mounted) return;
    final SrsNoteFieldPlan plan = await srsPlanSetField(
      store,
      <String>[noteId],
      fieldName,
      value,
    );
    if (plan.isEmpty) return;
    final SrsNoteFieldApplied applied = await srsApplyNoteFieldPlan(
      store,
      plan,
    );
    if (!mounted) return;
    if (applied.conflicts > 0) {
      FushiToast.show(
        msg: t.srs_browse_field_edit_conflicts(n: applied.conflicts),
        severity: ToastSeverity.warning,
      );
    }
    final SrsBatchRevert? revert = applied.outcome.revert;
    if (revert != null) _undo.add(_UndoEntry(revert));
    await _afterWrite(rerender: false);
  }

  /// 行所属的笔记类型（按名字；类型已不在 null）。
  SrsNoteTypeView? _typeOf(SrsBrowseRow row) => _noteTypes
      .where((SrsNoteTypeView n) => n.name == row.noteTypeName)
      .firstOrNull;

  /// 表格里一格对应的字段（正面 = 排序字段即第一个字段，字段摘要列 = 摘要来自的那个字段）；不是字段列 null。
  SrsFieldDef? _cellField(SrsBrowseRow row, SrsBrowseTableColumn column) {
    final SrsNoteTypeView? type = _typeOf(row);
    if (type == null || type.fields.isEmpty) return null;
    if (column == SrsBrowseTableColumn.front) return type.fields.first;
    final String? name = srsBrowsePreviewFieldName(row, column);
    if (name == null) return null;
    return type.fields.where((SrsFieldDef f) => f.name == name).firstOrNull;
  }

  /// 表格原地改的初值：字段取笔记里的原值（摘要去了 HTML、截过长度，拿它写回会丢内容），标签空格连接。
  Future<String?> _loadCell(
    SrsBrowseRow row,
    SrsBrowseTableColumn column,
  ) async {
    if (column == SrsBrowseTableColumn.tags) return row.tags.join(' ');
    final SrsFieldDef? field = _cellField(row, column);
    if (field == null) return null;
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return null;
    final SrsNoteView? note = await store.note(row.noteId);
    return note?.field(field.id);
  }

  /// 表格原地改一格：字段走 [_saveField]、标签走 [_saveTags]（都是条件写 + 进撤销栈）。
  Future<void> _saveCell(
    SrsBrowseRow row,
    SrsBrowseTableColumn column,
    String value,
  ) async {
    try {
      if (column == SrsBrowseTableColumn.tags) {
        await _saveTags(row.noteId, row.tags, parseSrsBrowseTagsCell(value));
        return;
      }
      final SrsFieldDef? field = _cellField(row, column);
      if (field == null) return;
      await _saveField(row.noteId, field.name, value);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsBrowse.cellEdit', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    }
  }

  /// 出处视图「只复习这一作」：在这部作品的卡所在牌组的最近公共祖先上开一轮自定义学习，只出这部作品今天到期的
  /// 复习卡与学习卡（内核 study.rs `CustomStudy` 的 `source`，按笔记缓存行的出处键查；不建筛选牌组、不挪卡）。
  /// 卡分在几个顶层牌组里时让用户挑一个。
  Future<void> _reviewSource(SrsBrowseSourceGroup group) async {
    final String? key = group.key;
    final SrsDbStore? store = await readSrsStore(ref);
    if (key == null || store == null || !mounted) return;
    final SrsDeckTree tree = await store.deckTree();
    if (!mounted) return;
    String? deckId = srsCommonDeckAncestor(tree, group.deckIds);
    if (deckId == null) {
      final List<String> roots = srsTopLevelDecks(tree, group.deckIds);
      if (roots.isEmpty) return;
      deckId = await _focusOwnership.guardOverlay(
        () => showFushiChoiceDialog<String>(
          context: context,
          title: t.srs_browse_source_review_pick,
          icon: FushiIcons.playCircle,
          options: <FushiChoiceOption<String>>[
            for (final String id in roots)
              FushiChoiceOption<String>(value: id, label: tree.fullName(id)),
          ],
        ),
      );
      if (deckId == null || !mounted) return;
    }
    final SrsCustomStudy custom = SrsCustomStudy(
      mode: SrsCustomStudyMode.filter,
      sinceMs: store.now().$1,
      limit: SrsCustomStudy.maxCards,
      states: const <SrsCustomStudyState>{
        SrsCustomStudyState.due,
        SrsCustomStudyState.learning,
      },
      source: key,
    );
    final String id = deckId;
    await srsPushPage<void>(
      context,
      (_) => SrsReviewPage(
        deckId: id,
        deckName: tree.fullName(id),
        custom: custom,
      ),
    );
    if (mounted) await _afterWrite();
  }

  /// 检查器里改标签：拆成加 / 删两步（一个撤销步，两段 revert 倒序执行）。
  Future<void> _saveTags(
    String noteId,
    List<String> before,
    List<String> after,
  ) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null || !mounted) return;
    final Set<String> b = before.toSet();
    final Set<String> a = after.toSet();
    final List<String> add = <String>[
      for (final String x in after)
        if (!b.contains(x)) x,
    ];
    final List<String> remove = <String>[
      for (final String x in before)
        if (!a.contains(x)) x,
    ];
    if (add.isEmpty && remove.isEmpty) return;
    // 失败抛给检查器（与 [_saveField] 同一约定）：由它记日志、提示，并把标签留作未保存。
    final SrsBatchOutcome out = await srsBatchEditTags(
      store,
      <String>[noteId],
      add: add,
      remove: remove,
    );
    if (out.revert != null) _undo.add(_UndoEntry(out.revert!));
    await _afterWrite(rerender: false);
  }

  /// 写入后：通知别的页面、重读写过的行。[rerender]：检查器的卡面 / 历史跟着重读（原地编辑时编辑页签自己
  /// 已是最新，不必整块重载）。
  Future<void> _afterWrite({bool rerender = true}) async {
    if (!mounted) return;
    bumpSrsRevision(ref);
    _revision++;
    _detailRevision.value = _revision;
    await _refresh();
  }

  // ------------------------------------------------------------------ 选择

  Future<void> _setCurrent(int index, {bool extend = false}) async {
    final SrsBrowseResult? r = _result;
    if (r == null || index < 0 || index >= r.length) return;
    try {
      await r.ensure(index, index + 1);
    } on SrsBrowseResultGone {
      _requery();
      return;
    }
    final SrsBrowseRow? row = r.rowAt(index);
    if (!mounted || row == null || !identical(r, _result)) return;
    final String id = r.idOf(row);
    if (extend) {
      await _selectRange(
        _anchorAt >= 0
            ? _anchorAt
            : (_currentIndex >= 0 ? _currentIndex : index),
        index,
      );
      if (!mounted || !identical(r, _result)) return;
    }
    setState(() {
      if (!extend) {
        _anchorId = id;
        _anchorAt = index;
      }
      if (_currentId != id) _showAnswer = false;
      _currentId = id;
      _currentAt = index;
    });
    _scrollToIndex(index);
  }

  /// 把第 [a]..[b] 行（含两端）加进选中（行 id 由原生会话按行号给出，不必先取那几页）。
  Future<void> _selectRange(int a, int b) async {
    final SrsBrowseResult? r = _result;
    if (r == null || a < 0 || b < 0) return;
    final List<String> ids;
    try {
      ids = await r.ids(math.min(a, b), math.max(a, b) + 1);
    } on SrsBrowseResultGone {
      _requery();
      return;
    }
    if (!mounted || !identical(r, _result)) return;
    setState(() => _selected.addAll(ids));
  }

  void _toggle(String id, int index) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
      _anchorId = id;
      _anchorAt = index;
      _currentId = id;
      _currentAt = index;
    });
  }

  Future<void> _selectAll() async {
    final SrsBrowseResult? r = _result;
    if (r == null) return;
    final List<String> ids;
    try {
      ids = await r.ids();
    } on SrsBrowseResultGone {
      _requery();
      return;
    }
    if (!mounted || !identical(r, _result)) return;
    setState(() {
      _selectMode = true;
      _selected
        ..clear()
        ..addAll(ids);
    });
  }

  void _clearSelection() {
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
  }

  void _onRowTap(String id, int index, {required bool wide}) {
    final HardwareKeyboard kb = HardwareKeyboard.instance;
    if (kb.isShiftPressed) {
      final int from = _anchorAt >= 0
          ? _anchorAt
          : (_currentIndex >= 0 ? _currentIndex : index);
      setState(() {
        _selectMode = true;
        _currentId = id;
        _currentAt = index;
      });
      unawaited(_selectRange(from, index));
      return;
    }
    if (kb.isControlPressed || kb.isMetaPressed || _selecting) {
      _toggle(id, index);
      return;
    }
    if (wide) {
      unawaited(_setCurrent(index));
    } else {
      setState(() {
        _currentId = id;
        _currentAt = index;
      });
      unawaited(_openDetail(index));
    }
  }

  void _onRowLongPress(String id, int index) {
    setState(() => _selectMode = true);
    _toggle(id, index);
  }

  void _scrollToIndex(int index) {
    if (!_scroll.hasClients) return;
    // 行高不固定：先按估计行高把目标行滚进视口附近，再按真实几何对齐。
    const double estimate = 72;
    final ScrollPosition p = _scroll.position;
    final double target = (index * estimate).clamp(
      p.minScrollExtent,
      p.maxScrollExtent,
    );
    final double top = p.pixels;
    final double bottom = top + p.viewportDimension - estimate * 2;
    if (target < top || target > bottom) {
      _scroll.jumpTo(
        (target - p.viewportDimension / 3).clamp(
          p.minScrollExtent,
          p.maxScrollExtent,
        ),
      );
    }
  }

  void _onRowSecondaryTap(String id, int index) {
    if (!_selected.contains(id)) {
      setState(() {
        _selected
          ..clear()
          ..add(id);
        _currentId = id;
        _currentAt = index;
      });
    }
    srsRunLogged('SrsBrowse.contextMenu', _openBatchMenu);
  }

  // ------------------------------------------------------------------ 导航

  /// 手机：全屏详情页（预览 / 编辑 / 历史，左右切换上一张 / 下一张）。
  Future<void> _openDetail(int index) async {
    final SrsBrowseResult? result = _result;
    if (result == null) return;
    final int before = _revision;
    await _focusOwnership.guardOverlay(
      () => srsPushPage<void>(
        context,
        (_) => SrsBrowseDetailPage(
          result: result,
          initialIndex: index,
          revision: _detailRevision,
          onSaveField: _saveField,
          onSaveTags: _saveTags,
          onOpenEditor: _editNoteFromDetail,
          actionsFor: (SrsBrowseRow row) {
            final String id = _mode == SrsBrowseMode.cards
                ? row.cardId
                : row.noteId;
            return SrsBrowseInspectorActions(
              suspended: row.isSuspended,
              onSuspend: () => unawaited(
                _runBatch(
                  SrsBrowseBatchAction.toggleSuspend,
                  ids: <String>[id],
                ),
              ),
              onFlag: () => unawaited(
                _runBatch(SrsBrowseBatchAction.flag, ids: <String>[id]),
              ),
              onMore: () => srsRunLogged(
                'SrsBrowseDetail.more',
                () => _openBatchMenu(ids: <String>[id]),
              ),
            );
          },
        ),
      ),
    );
    // 详情页只读时原生侧直接给回同一份结果，不重算；写过就按 id 增量重读。
    if (mounted) await _refresh(reuse: _revision == before);
  }

  Future<void> _editNoteFromDetail(String noteId) async {
    await srsPushPage<void>(context, (_) => SrsNoteEditorPage(noteId: noteId));
    if (mounted) await _afterWrite();
  }

  Future<void> _editNote(String noteId) async {
    await _focusOwnership.guardOverlay(
      () =>
          srsPushPage<void>(context, (_) => SrsNoteEditorPage(noteId: noteId)),
    );
    await _afterWrite();
  }

  /// 「新卡片」：笔记编辑器新建（落在编辑器默认的牌组）。
  Future<void> _newNote() async {
    await _focusOwnership.guardOverlay(
      () => srsPushPage<void>(context, (_) => const SrsNoteEditorPage()),
    );
    await _afterWrite();
  }

  void _onPreviewCommand(SrsPreviewCommand c) {
    switch (c) {
      case SrsPreviewCommand.flip:
        setState(() => _showAnswer = !_showAnswer);
      case SrsPreviewCommand.previous:
        unawaited(_setCurrent(_currentIndex - 1));
      case SrsPreviewCommand.next:
        unawaited(_setCurrent(_currentIndex + 1));
      case SrsPreviewCommand.undo:
        _undoLast();
      case SrsPreviewCommand.escape:
        if (_selecting) _clearSelection();
    }
  }

  // ------------------------------------------------------------------ 批量

  List<SrsBrowseBatchAction> get _batchActions => <SrsBrowseBatchAction>[
    SrsBrowseBatchAction.toggleSuspend,
    SrsBrowseBatchAction.toggleBury,
    SrsBrowseBatchAction.flag,
    SrsBrowseBatchAction.move,
    SrsBrowseBatchAction.addTags,
    SrsBrowseBatchAction.removeTags,
    SrsBrowseBatchAction.setCardType,
    SrsBrowseBatchAction.setField,
    SrsBrowseBatchAction.findReplace,
    if (_canSchedule) SrsBrowseBatchAction.reset,
    if (_canSchedule) SrsBrowseBatchAction.setDue,
    if (widget.onChangeNoteType != null) SrsBrowseBatchAction.changeNoteType,
    if (widget.onMigrateToFushiCard != null)
      SrsBrowseBatchAction.migrateToFushiCard,
    SrsBrowseBatchAction.delete,
  ];

  Future<void> _openBatchMenu({List<String>? ids}) async {
    if (ids == null && !_hasTargets) return;
    final SrsBrowseBatchAction? a = await _focusOwnership.guardOverlay(
      () => pickSrsBrowseBatchAction(
        context,
        actions: _batchActions,
        title: ids != null || _selected.isEmpty
            ? t.srs_browse_batch_actions
            : t.srs_browse_selected_count(n: _selected.length),
      ),
    );
    if (a == null || !mounted) return;
    await _runBatch(a, ids: ids);
  }

  Future<void> _runBatch(
    SrsBrowseBatchAction action, {
    List<String>? ids,
  }) async {
    if ((ids == null && !_hasTargets) || _busy) return;
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null || !mounted) return;
    final SrsBrowseTargets? targets = await _loadTargets(ids: ids);
    if (targets == null || targets.isEmpty || !mounted) return;
    final List<String> cardIds = targets.cardIds;
    final List<String> noteIds = targets.noteIds;

    Future<SrsBatchOutcome> Function()? run;
    String? doneMessage;
    // 批量改笔记字段：落库是条件写，计划之后又被改过的笔记不覆盖；条数随结果 toast 提示。
    int conflicts = 0;
    Future<SrsBatchOutcome> Function() fieldRun(
      Future<SrsNoteFieldApplied> Function() apply,
    ) => () async {
      final SrsNoteFieldApplied applied = await apply();
      conflicts = applied.conflicts;
      return applied.outcome;
    };
    switch (action) {
      case SrsBrowseBatchAction.toggleSuspend:
        final bool suspend = !targets.allSuspended;
        run = () => srsBatchSetSuspended(store, cardIds, suspended: suspend);
        doneMessage = suspend
            ? t.srs_browse_suspended
            : t.srs_browse_unsuspended;
      case SrsBrowseBatchAction.toggleBury:
        final bool bury = !targets.allBuried;
        run = () => srsBatchSetBuried(store, cardIds, buried: bury);
      case SrsBrowseBatchAction.flag:
        final Set<int> flags = targets.flags;
        final int? flag = await _focusOwnership.guardOverlay(
          () => pickSrsFlag(
            context,
            selected: flags.length == 1 ? flags.single : null,
          ),
        );
        if (flag == null) return;
        run = () => srsBatchSetFlag(store, cardIds, flag);
      case SrsBrowseBatchAction.move:
        final List<SrsDeckSummary> decks = await store.deckSummaries();
        if (!mounted) return;
        final Set<String> current = targets.deckIds;
        final String? deck = await _focusOwnership.guardOverlay(
          () => pickSrsDeck(
            context,
            decks: decks,
            selected: current.length == 1 ? current.single : null,
            title: t.srs_card_move,
          ),
        );
        if (deck == null) return;
        run = () => srsBatchMoveCards(store, cardIds, deck);
      case SrsBrowseBatchAction.addTags || SrsBrowseBatchAction.removeTags:
        final bool add = action == SrsBrowseBatchAction.addTags;
        final String? text = await _focusOwnership.guardOverlay(
          () => showFushiTextInputDialog(
            context: context,
            title: add ? t.srs_browse_tags_add : t.srs_browse_tags_remove,
            hintText: t.srs_note_tags_hint,
            icon: FushiIcons.tag,
          ),
        );
        if (text == null) return;
        final List<String> tags = srsParseTags(text);
        if (tags.isEmpty) return;
        run = () => srsBatchEditTags(
          store,
          noteIds,
          add: add ? tags : const <String>[],
          remove: add ? const <String>[] : tags,
        );
      case SrsBrowseBatchAction.setCardType:
        final SrsCardType? type = await _focusOwnership.guardOverlay(
          () => pickSrsCardType(context),
        );
        if (type == null || !mounted) return;
        final SrsNoteFieldPlan? plan = await _planFieldEdit(
          action,
          () => srsPlanCardType(store, noteIds, type),
        );
        if (plan == null) return;
        final Future<SrsNoteFieldApplied> Function()? apply =
            await _confirmFieldPlan(store, t.srs_browse_card_type_set, plan);
        if (apply == null) return;
        run = fieldRun(apply);
      case SrsBrowseBatchAction.setField:
        final List<String> fieldNames = _fieldNames;
        if (fieldNames.isEmpty) return;
        final String? field = await _focusOwnership.guardOverlay(
          () => pickSrsBrowseField(
            context,
            fieldNames: fieldNames,
            selected: null,
            title: t.srs_browse_field_set,
            allowAll: false,
          ),
        );
        if (field == null || !mounted) return;
        final String? value = await _focusOwnership.guardOverlay(
          () => showFushiTextInputDialog(
            context: context,
            title: t.srs_browse_field_value_title(field: field),
            hintText: t.srs_browse_field_value_hint,
            icon: FushiIcons.edit,
            allowEmpty: true,
            trim: false,
            maxLines: 4,
          ),
        );
        if (value == null || !mounted) return;
        final SrsNoteFieldPlan? plan = await _planFieldEdit(
          action,
          () => srsPlanSetField(store, noteIds, field, value),
        );
        if (plan == null) return;
        final Future<SrsNoteFieldApplied> Function()? apply =
            await _confirmFieldPlan(store, t.srs_browse_field_set, plan);
        if (apply == null) return;
        run = fieldRun(apply);
      case SrsBrowseBatchAction.findReplace:
        final SrsNoteFieldPlan? plan = await _focusOwnership.guardOverlay(
          () => showSrsFindReplaceDialog<SrsNoteFieldPlan>(
            context,
            fieldNames: _fieldNames,
            onSubmit: (SrsFindReplaceRequest r) => srsPlanFindReplace(
              store,
              noteIds,
              fieldName: r.fieldName,
              find: r.find,
              replace: r.replace,
              regex: r.regex,
              caseSensitive: r.caseSensitive,
            ),
          ),
        );
        if (plan == null || !mounted) return;
        final Future<SrsNoteFieldApplied> Function()? apply =
            await _confirmFieldPlan(store, t.srs_browse_find_replace, plan);
        if (apply == null) return;
        run = fieldRun(apply);
      case SrsBrowseBatchAction.reset:
        final bool ok = await _focusOwnership.guardOverlay(
          () => showFushiConfirmDialog(
            context: context,
            title: t.srs_card_reset,
            message: t.srs_browse_reset_confirm(n: cardIds.length),
            confirmLabel: t.srs_card_reset,
            cancelLabel: t.cancel,
            icon: FushiIcons.restart,
            destructive: true,
          ),
        );
        if (!ok) return;
        run = () => srsBatchResetCards(store, cardIds);
      case SrsBrowseBatchAction.setDue:
        final String? text = await _focusOwnership.guardOverlay(
          () => showFushiTextInputDialog(
            context: context,
            title: t.srs_browse_set_due,
            message: t.srs_browse_set_due_hint,
            hintText: '0, 3, 1-7',
            icon: FushiIcons.calendar,
            validator: (String v) =>
                v.trim().isEmpty || srsParseDueDays(v) != null
                ? null
                : t.srs_browse_set_due_invalid,
          ),
        );
        final (int, int)? range = text == null ? null : srsParseDueDays(text);
        if (range == null) return;
        run = () =>
            srsBatchSetDue(store, cardIds, from: range.$1, to: range.$2);
      case SrsBrowseBatchAction.delete:
        final bool ok = await _focusOwnership.guardOverlay(
          () => showFushiConfirmDialog(
            context: context,
            title: t.srs_browse_delete_notes,
            message: t.srs_browse_delete_confirm(n: noteIds.length),
            confirmLabel: t.srs_note_delete,
            cancelLabel: t.cancel,
            icon: FushiIcons.delete,
            destructive: true,
          ),
        );
        if (!ok) return;
        run = () => srsBatchDeleteNotes(store, noteIds);
      case SrsBrowseBatchAction.changeNoteType:
      case SrsBrowseBatchAction.migrateToFushiCard:
        final SrsChangeNoteTypeFlow? flow =
            action == SrsBrowseBatchAction.changeNoteType
            ? widget.onChangeNoteType
            : widget.onMigrateToFushiCard;
        if (flow == null) return;
        await _focusOwnership.guardOverlay(() => flow(context, noteIds));
        if (!mounted) return;
        await _afterWrite();
        return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final SrsBatchOutcome out = await run();
      if (!mounted) return;
      if (out.revert != null) _undo.add(_UndoEntry(out.revert!));
      if (conflicts > 0) {
        FushiToast.show(
          msg: t.srs_browse_field_edit_conflicts(n: conflicts),
          severity: ToastSeverity.warning,
        );
      } else if (out.changed == 0) {
        FushiToast.show(msg: t.srs_browse_nothing_changed);
      } else {
        FushiToast.show(msg: doneMessage ?? t.srs_browse_done(n: out.changed));
      }
      bumpSrsRevision(ref);
      _revision++;
      // 原生会话按 id 重读这次写过的行（增量），再按同样的条件重算。
      await _refresh();
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsBrowse.batch.${action.name}', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 算批量改笔记字段的计划（要物化整份结果集的笔记）：计划期间置 [_busy]（批量菜单、Delete、
  /// 撤销都不能插进来），出错与落库同样记日志 + 失败 toast，返回 null。
  Future<SrsNoteFieldPlan?> _planFieldEdit(
    SrsBrowseBatchAction action,
    Future<SrsNoteFieldPlan> Function() plan,
  ) async {
    if (!mounted) return null;
    setState(() => _busy = true);
    try {
      return await plan();
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsBrowse.plan.${action.name}', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 批量改笔记字段的计划 → 确认。空计划：有笔记因类型没有所需字段被跳过就报跳过条数，否则
  /// 「没有改动」；取消返回 null；确认后返回落库动作（结果交给 [_runBatch] 的撤销栈与 toast）。
  Future<Future<SrsNoteFieldApplied> Function()?> _confirmFieldPlan(
    SrsDbStore store,
    String title,
    SrsNoteFieldPlan plan,
  ) async {
    if (!mounted) return null;
    if (plan.isEmpty) {
      final ({String message, bool warning}) notice =
          srsNoteFieldPlanEmptyNotice(plan);
      FushiToast.show(
        msg: notice.message,
        severity: notice.warning
            ? ToastSeverity.warning
            : ToastSeverity.neutral,
      );
      return null;
    }
    final bool ok = await _focusOwnership.guardOverlay(
      () => confirmSrsNoteFieldPlan(context, title: title, plan: plan),
    );
    if (!ok || !mounted) return null;
    return () => srsApplyNoteFieldPlan(store, plan);
  }

  void _undoLast() {
    if (_undo.isEmpty || _busy) return;
    srsRunLogged('SrsBrowse.undo', () async {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null || !mounted) return;
      final _UndoEntry entry = _undo.removeLast();
      setState(() => _busy = true);
      try {
        final int blocked = await entry.revert(store);
        FushiToast.show(
          msg: blocked > 0
              ? t.srs_browse_undo_partial(n: blocked)
              : t.srs_browse_undone,
          severity: blocked > 0 ? ToastSeverity.warning : ToastSeverity.neutral,
        );
        if (!mounted) return;
        await _afterWrite();
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    });
  }

  // ------------------------------------------------------------------ 键盘

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final KeyEventResult? lookup = _previewLookup.guardKey(event);
    if (lookup != null) return lookup;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    final HardwareKeyboard kb = HardwareKeyboard.instance;
    final bool ctrl = kb.isControlPressed || kb.isMetaPressed;
    if (ctrl && key == LogicalKeyboardKey.keyF) {
      _queryFocus.requestFocus();
      return KeyEventResult.handled;
    }
    // 文本框持焦：方向键 / Enter / Ctrl+A / Ctrl+Z 都归文本编辑。
    if (_editingText) return KeyEventResult.ignored;
    if (event is KeyRepeatEvent &&
        key != LogicalKeyboardKey.arrowDown &&
        key != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    if (ctrl && key == LogicalKeyboardKey.keyZ) {
      _undoLast();
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyA) {
      unawaited(_selectAll());
      return KeyEventResult.handled;
    }
    if (ctrl || kb.isAltPressed) return KeyEventResult.ignored;
    final bool wide =
        MediaQuery.sizeOf(context).width >= kSrsBrowseSplitMinWidth;
    switch (key) {
      case LogicalKeyboardKey.arrowDown:
        unawaited(
          _setCurrent(
            math.max(0, _currentIndex + 1),
            extend: kb.isShiftPressed,
          ),
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        unawaited(
          _setCurrent(
            math.max(0, _currentIndex - 1),
            extend: kb.isShiftPressed,
          ),
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter ||
          LogicalKeyboardKey.numpadEnter ||
          LogicalKeyboardKey.gameButtonA:
        final int i = _currentIndex;
        if (i < 0) return KeyEventResult.ignored;
        if (wide) {
          setState(() => _showAnswer = !_showAnswer);
        } else {
          unawaited(_openDetail(i));
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        if (!_selecting) return KeyEventResult.ignored;
        _clearSelection();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.delete:
        if (!_hasTargets) return KeyEventResult.ignored;
        unawaited(_runBatch(SrsBrowseBatchAction.delete));
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------------ 界面

  String get _countText => _mode == SrsBrowseMode.cards
      ? t.srs_browse_count_cards(n: _length)
      : t.srs_browse_count(n: _length);

  List<FushiToolbarItem> _layoutItems(bool wide) => <FushiToolbarItem>[
    for (final _SrsBrowseLayout l in _SrsBrowseLayout.values)
      if (wide || l != _SrsBrowseLayout.table)
        FushiToolbarItem(
          key: ValueKey<String>('srs-browse-layout-${l.name}'),
          icon: switch (l) {
            _SrsBrowseLayout.list => FushiIcons.viewAgenda,
            _SrsBrowseLayout.table => FushiIcons.viewColumn,
            _SrsBrowseLayout.sources => FushiIcons.books,
          },
          label: switch (l) {
            _SrsBrowseLayout.list => t.srs_browse_view_list,
            _SrsBrowseLayout.table => t.srs_browse_view_table,
            _SrsBrowseLayout.sources => t.srs_browse_view_sources,
          },
          selected: _layoutFor(wide) == l,
          onPressed: () => _setLayout(l),
        ),
  ];

  List<FushiToolbarItem> _toolbarItems() => <FushiToolbarItem>[
    FushiToolbarItem(
      key: const ValueKey<String>('srs_browse_undo'),
      icon: FushiIcons.undo,
      label: t.undo,
      tooltip: '${t.undo} (Ctrl+Z)',
      onPressed: _undo.isEmpty || _busy ? null : _undoLast,
    ),
    if (_selecting) ...<FushiToolbarItem>[
      FushiToolbarItem(
        key: const ValueKey<String>('srs_browse_select_all'),
        icon: FushiIcons.selectAll,
        label: t.srs_browse_select_all,
        tooltip: '${t.srs_browse_select_all} (Ctrl+A)',
        onPressed: () => unawaited(_selectAll()),
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('srs_browse_batch'),
        icon: FushiIcons.checklist,
        label: t.srs_browse_batch_actions,
        selected: true,
        onPressed: _selected.isEmpty || _busy
            ? null
            : () => srsRunLogged('SrsBrowse.batchMenu', _openBatchMenu),
      ),
    ] else
      FushiToolbarItem(
        key: const ValueKey<String>('srs_browse_select'),
        icon: FushiIcons.checklist,
        label: t.srs_browse_select,
        onPressed: () => setState(() => _selectMode = true),
      ),
    FushiToolbarItem(
      key: const ValueKey<String>('srs-browse-new-card'),
      icon: FushiIcons.add,
      label: t.srs_browse_new_card,
      onPressed: () => srsRunLogged('SrsBrowse.newCard', _newNote),
    ),
  ];

  List<FushiToolbarItem> _overflowItems() => <FushiToolbarItem>[
    FushiToolbarItem(
      key: const ValueKey<String>('srs_browse_help'),
      icon: FushiIcons.help,
      label: t.srs_browse_search_help,
      onPressed: _openHelp,
    ),
    FushiToolbarItem(
      icon: FushiIcons.refresh,
      label: t.refresh,
      onPressed: () => unawaited(_refresh()),
    ),
  ];

  void _openHelp() => srsRunLogged(
    'SrsBrowse.help',
    () => _focusOwnership.guardOverlay(() => showSrsBrowseSearchHelp(context)),
  );

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final bool wide =
        MediaQuery.sizeOf(context).width >= kSrsBrowseSplitMinWidth;
    final Widget controls = _buildControls(context, wide: wide);
    final String title = _selecting
        ? t.srs_browse_selected_count(n: _selected.length)
        : t.srs_browse_title;
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: FushiPageScaffold(
        title: title,
        subtitle: apple ? _countText : null,
        header: apple ? null : _buildTopBar(context, wide: wide),
        actions: apple
            ? <Widget>[
                for (final FushiToolbarItem item in <FushiToolbarItem>[
                  ..._toolbarItems(),
                  ..._overflowItems(),
                ])
                  FushiIconButton(
                    key: item.key,
                    icon: item.icon,
                    tooltip: item.tooltip ?? item.label,
                    enabled: item.onPressed != null,
                    selected: item.selected,
                    onTap: item.onPressed,
                  ),
              ]
            : const <Widget>[],
        headerBottom: apple
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: FushiDesignTokens.of(context).spacing.gap,
                children: <Widget>[
                  _buildLayoutSegments(context, wide: wide),
                  controls,
                ],
              )
            : null,
        body: Builder(
          builder: (BuildContext context) {
            final Widget main = _buildMain(
              context,
              apple ? null : controls,
              wide: wide,
            );
            if (!wide) return main;
            return _buildSplit(context, main);
          },
        ),
      ),
    );
  }

  /// Apple 版顶栏下的视图切换（MD3 版在浮动顶栏里平铺）。
  Widget _buildLayoutSegments(BuildContext context, {required bool wide}) =>
      adaptiveSegmentedButton<_SrsBrowseLayout>(
        context: context,
        segments: <ButtonSegment<_SrsBrowseLayout>>[
          for (final FushiToolbarItem i in _layoutItems(wide))
            ButtonSegment<_SrsBrowseLayout>(
              value: _SrsBrowseLayout.values.byName(
                (i.key! as ValueKey<String>).value.substring(
                  'srs-browse-layout-'.length,
                ),
              ),
              label: Text(i.label),
            ),
        ],
        selected: <_SrsBrowseLayout>{_layoutFor(wide)},
        onSelectionChanged: (Set<_SrsBrowseLayout> v) => _setLayout(v.first),
      );

  Widget _buildTopBar(BuildContext context, {required bool wide}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: FushiFloatingTopBar(
        title: _selecting
            ? t.srs_browse_selected_count(n: _selected.length)
            : t.srs_browse_title,
        subtitle: _countText,
        leading: <FushiToolbarItem>[
          if (_selecting)
            FushiToolbarItem(
              key: const ValueKey<String>('srs_browse_clear_selection'),
              icon: FushiIcons.close,
              label: t.srs_browse_select_none,
              onPressed: _clearSelection,
            )
          else if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[_toolbarItems(), _layoutItems(wide)],
        overflow: _overflowItems(),
      ),
    );
  }

  /// 搜索积木栏 + 快捷视图条 + （宽屏）健康条 + 「N 张 · 按 X」排序行。
  Widget _buildControls(BuildContext context, {required bool wide}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final Color muted = apple
        ? appleColorsOf(context).secondaryLabel
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final SrsBrowseHealthCounts? health = _health;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        SrsBrowseQueryBar(
          chips: _chips,
          draft: _draft,
          focusNode: _queryFocus,
          fieldScope: _searchField,
          suggestions: _suggestions,
          error: _searchError,
          onDraftChanged: _onDraftChanged,
          onDraftSubmitted: _onDraftSubmitted,
          onChipTap: (int i) =>
              srsRunLogged('SrsBrowse.chip', () => _editChip(i)),
          onChipRemove: (int i) =>
              _setChips(srsBrowseReplaceChip(_chips, i, null)),
          onRemoveLast: () =>
              _setChips(srsBrowseReplaceChip(_chips, _chips.length - 1, null)),
          onSuggestion: (SrsBrowseSuggestion s) {
            _draft.clear();
            _setChips(<SrsBrowseChip>[..._chips, s.chip]);
          },
          onPickField: () => srsRunLogged('SrsBrowse.field', _pickField),
          onHelp: _openHelp,
          onSaveView: _effectiveQuery.trim().isEmpty
              ? null
              : () => srsRunLogged('SrsBrowse.saveView', _saveView),
        ),
        SrsBrowseViewStrip(entries: _viewEntries()),
        if (wide && health != null)
          SrsBrowseHealthBar(
            counts: health,
            onViewEmptyField: () => _applyView(kSrsBrowseHealthEmptyQuery),
            onViewMissingAudio: () {
              final String? fushi = _fushiNoteTypeName;
              if (fushi != null) _applyView(srsBrowseMissingAudioQuery(fushi));
            },
            onViewHard: () => _applyView(kSrsBrowseHealthHardQuery),
            onViewDupes: () => _applyView(kSrsBrowseHealthDupesQuery),
          ),
        Row(
          spacing: tokens.spacing.gap,
          children: <Widget>[
            Expanded(
              child: Text(
                '$_countText · ${srsBrowseSortLabel(_sort)}',
                key: const ValueKey<String>('srs-browse-summary'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.labelLarge.copyWith(color: muted),
              ),
            ),
            FushiIconButton(
              key: const ValueKey<String>('srs-browse-sort'),
              icon: FushiIcons.sort,
              tooltip: srsBrowseSortLabel(_sort),
              onTap: () => srsRunLogged('SrsBrowse.sort', _pickSort),
            ),
            FushiIconButton(
              key: const ValueKey<String>('srs-browse-direction'),
              icon: _sort.ascending ? FushiIcons.arrowUp : FushiIcons.arrowDown,
              tooltip: _sort.ascending
                  ? t.srs_browse_sort_ascending
                  : t.srs_browse_sort_descending,
              onTap: () {
                setState(
                  () => _sort = _sort.copyWith(ascending: !_sort.ascending),
                );
                _requery();
              },
            ),
            FushiIconButton(
              key: const ValueKey<String>('srs-browse-mode'),
              icon: _mode == SrsBrowseMode.cards
                  ? FushiIcons.ankiCard
                  : FushiIcons.viewAgenda,
              tooltip: _mode == SrsBrowseMode.cards
                  ? t.srs_browse_mode_cards
                  : t.srs_browse_mode_notes,
              onTap: _toggleMode,
            ),
            if (wide && _layout == _SrsBrowseLayout.table) ...<Widget>[
              FushiIconButton(
                key: const ValueKey<String>('srs-browse-columns-button'),
                icon: FushiIcons.viewColumn,
                tooltip: t.srs_browse_table_columns,
                onTap: () => srsRunLogged('SrsBrowse.columns', _pickColumns),
              ),
              FushiIconButton(
                key: const ValueKey<String>('srs-browse-group-button'),
                icon: FushiIcons.gridView,
                selected: _group != SrsBrowseTableGroup.none,
                tooltip: t.srs_browse_table_group,
                onTap: () => srsRunLogged('SrsBrowse.group', _pickGroup),
              ),
            ],
          ],
        ),
      ],
    );
  }

  void _toggleMode() {
    setState(() {
      _mode = _mode == SrsBrowseMode.cards
          ? SrsBrowseMode.notes
          : SrsBrowseMode.cards;
      _selected.clear();
      _currentId = null;
    });
    _requery();
  }

  /// 右侧检查器。当前行在换页 / 重查的空档里暂时取不到时，留着上一次的行（检查器与卡面不卸载）。
  Widget _buildSplit(BuildContext context, Widget list) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final int index = _currentIndex;
    final SrsBrowseRow? fresh = index < 0 ? null : _result?.rowAt(index);
    if (fresh != null) _shownRow = fresh;
    if (index < 0 && _length == 0) _shownRow = null;
    final SrsBrowseRow? item = _shownRow;
    final EdgeInsets inset = MediaQuery.paddingOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(flex: 5, child: list),
        Expanded(
          flex: 6,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              0,
              tokens.spacing.gap + inset.top,
              tokens.spacing.page,
              tokens.spacing.section + inset.bottom,
            ),
            child: item == null
                ? Center(
                    child: FushiPlaceholderMessage(
                      icon: FushiIcons.ankiCard,
                      message: t.srs_browse_preview_empty,
                    ),
                  )
                : SrsBrowseInspector(
                    row: item,
                    revision: _revision,
                    tab: _inspectorTab,
                    onTabChanged: (SrsBrowseInspectorTab v) =>
                        setState(() => _inspectorTab = v),
                    showAnswer: _showAnswer,
                    position: index < 0 ? null : '${index + 1} / $_length',
                    hasPrevious: index > 0,
                    hasNext: index >= 0 && index < _length - 1,
                    onCommand: _onPreviewCommand,
                    onSaveField: _saveField,
                    onSaveTags: _saveTags,
                    onOpenEditor: (String noteId) =>
                        srsRunLogged('SrsBrowse.edit', () => _editNote(noteId)),
                    actions: _inspectorActions(item),
                    lookup: _previewLookup,
                    onLookupClosed: () => _focusOwnership.reclaim(
                      FocusReclaimCause.overlayClosed,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  SrsBrowseInspectorActions _inspectorActions(SrsBrowseRow row) {
    final String id = _mode == SrsBrowseMode.cards ? row.cardId : row.noteId;
    return SrsBrowseInspectorActions(
      suspended: row.isSuspended,
      onSuspend: () => unawaited(
        _runBatch(SrsBrowseBatchAction.toggleSuspend, ids: <String>[id]),
      ),
      onFlag: () =>
          unawaited(_runBatch(SrsBrowseBatchAction.flag, ids: <String>[id])),
      onMore: () => srsRunLogged('SrsBrowse.inspectorMore', () async {
        if (_selected.isEmpty) {
          setState(() {
            _currentId = id;
          });
        }
        await _openBatchMenu();
      }),
    );
  }

  EdgeInsets _listPadding(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return withBottomSafeInset(
      context,
      EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap + MediaQuery.paddingOf(context).top,
        tokens.spacing.page,
        tokens.spacing.section,
      ),
    );
  }

  Widget _buildMain(
    BuildContext context,
    Widget? controls, {
    required bool wide,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    final Object? loadError = _loadError;
    if (loadError != null) {
      return SrsLoadErrorView(
        key: const ValueKey<String>('srs-browse-load-error'),
        error: loadError,
        retryKey: const ValueKey<String>('srs-browse-load-retry'),
        onRetry: _retryLoad,
      );
    }
    final SrsBrowseResult? result = _result;
    if (result == null || result.length == 0) {
      return ListView(
        padding: _listPadding(context),
        children: <Widget>[
          ?controls,
          SizedBox(height: tokens.spacing.section),
          FushiPlaceholderMessage(
            icon: FushiIcons.searchOff,
            message: t.srs_browse_empty,
          ),
        ],
      );
    }
    final _SrsBrowseLayout layout = _layoutFor(wide);
    final Widget body = switch (layout) {
      _SrsBrowseLayout.table => SrsBrowseTable(
        length: result.length,
        rowAt: result.rowAt,
        loadRow: (int i) => _loadRow(result, i),
        idOf: result.idOf,
        columns: _columns,
        group: _group,
        sort: _effectiveSort,
        selected: _selected,
        currentId: _currentId,
        controller: _scroll,
        onSort: (SrsBrowseSortColumn c) {
          setState(() {
            _group = SrsBrowseTableGroup.none;
            _sort = _sort.column == c
                ? _sort.copyWith(ascending: !_sort.ascending)
                : SrsBrowseSort(column: c);
          });
          _requery();
        },
        onRowTap: (String id, int i) => _onRowTap(id, i, wide: true),
        onRowSecondaryTap: _onRowSecondaryTap,
        loadCell: _loadCell,
        onSaveCell: _saveCell,
        header: controls,
      ),
      _SrsBrowseLayout.sources => SrsBrowseSourcesView(
        result: result,
        revision: _revision,
        idOf: result.idOf,
        selected: _selected,
        onOnlySource: (String? key) => _applyView(srsSourceQuery(key)),
        onReviewSource: (SrsBrowseSourceGroup g) =>
            srsRunLogged('SrsBrowse.reviewSource', () => _reviewSource(g)),
        onOpen: (String id, int i) => _onRowTap(id, i, wide: wide),
        header: controls,
      ),
      _SrsBrowseLayout.list => _buildList(
        context,
        result,
        controls,
        wide: wide,
      ),
    };
    // 视图切换淡入（不用 AnimatedSwitcher 交叉淡出：新旧两份会同时挂着搜索框，同一个 FocusNode 不能挂两处）。
    return TweenAnimationBuilder<double>(
      key: ValueKey<_SrsBrowseLayout>(layout),
      tween: Tween<double>(begin: 0, end: 1),
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.enter,
      builder: (BuildContext context, double v, Widget? child) =>
          Opacity(opacity: v, child: child),
      child: body,
    );
  }

  Widget _buildList(
    BuildContext context,
    SrsBrowseResult result,
    Widget? controls, {
    required bool wide,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final int offset = controls == null ? 0 : 1;
    // 宽屏卡片列表区够宽时两列（spec ⑥）。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final int columns = c.maxWidth >= 720 ? 2 : 1;
        final int rows = (result.length + columns - 1) ~/ columns;
        return FushiEntranceScope(
          replayKey: '$_effectiveQuery|${_mode.name}',
          child: ListView.builder(
            controller: _scroll,
            padding: _listPadding(context),
            itemCount: rows + offset,
            itemBuilder: fushiStaggeredItemBuilder((
              BuildContext context,
              int i,
            ) {
              if (controls != null && i == 0) {
                return Padding(
                  padding: EdgeInsets.only(bottom: tokens.spacing.gap * 1.5),
                  child: controls,
                );
              }
              final int line = i - offset;
              if (columns == 1) {
                return Padding(
                  padding: EdgeInsets.only(bottom: tokens.spacing.gap),
                  child: _buildRow(context, line, wide: wide),
                );
              }
              return Padding(
                padding: EdgeInsets.only(bottom: tokens.spacing.gap),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: tokens.spacing.gap,
                  children: <Widget>[
                    for (int k = 0; k < columns; k++)
                      Expanded(
                        child: line * columns + k < result.length
                            ? _buildRow(context, line * columns + k, wide: wide)
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
              );
            }),
          ),
        );
      },
    );
  }

  Widget _buildRow(BuildContext context, int index, {required bool wide}) {
    final SrsBrowseResult r = _result!;
    final SrsBrowseRow? c = r.rowAt(index);
    if (c == null) {
      // 这一页还没取：先占一行高度，取到后重画。
      _loadRow(r, index);
      return SizedBox(
        key: ValueKey<String>('srs-browse-row-pending-$index'),
        height: 96,
      );
    }
    final String id = r.idOf(c);
    final bool selected = _selected.contains(id);
    final bool current = id == _currentId && (wide || _selecting);
    final Widget tile = SrsBrowseCardTile(
      row: c,
      id: id,
      cardsMode: _mode == SrsBrowseMode.cards,
      selected: selected,
      current: current,
      selecting: _selecting,
      onTap: () => _onRowTap(id, index, wide: wide),
      onLongPress: () => _onRowLongPress(id, index),
      onSecondaryTap: () => _onRowSecondaryTap(id, index),
      onToggle: () => _toggle(id, index),
    );
    if (wide) return tile;
    // 手机：左滑露出暂停 / 旗标（spec ①）。
    return SrsBrowseSwipeReveal(
      enabled: !_selecting && !_busy,
      actions: <SrsBrowseSwipeAction>[
        SrsBrowseSwipeAction(
          keyName: 'srs-browse-swipe-suspend-$id',
          icon: c.isSuspended ? FushiIcons.play : FushiIcons.pause,
          label: c.isSuspended
              ? t.srs_browse_swipe_unsuspend
              : t.srs_browse_swipe_suspend,
          onPressed: () => unawaited(
            _runBatch(SrsBrowseBatchAction.toggleSuspend, ids: <String>[id]),
          ),
        ),
        SrsBrowseSwipeAction(
          keyName: 'srs-browse-swipe-flag-$id',
          icon: FushiIcons.flag,
          label: t.srs_card_flag,
          onPressed: () => unawaited(
            _runBatch(SrsBrowseBatchAction.flag, ids: <String>[id]),
          ),
        ),
      ],
      child: tile,
    );
  }
}
