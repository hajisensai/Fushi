// 开发者反馈处理台（App 内；网页版是同一服务的 /dev）。只有排行榜账户 role = dev
// 才看得到入口，权限以服务端为准（非开发者调接口一律 403）。
//
// 列表按状态筛选、游标分页；详情含反馈人 / 联系方式 / 设备信息 / 截图 / 日志，
// 改状态与回复在同一个表单里一次保存。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_common.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';

/// 列表筛选：未结案 / 各状态 / 全部（wire 值；null = 全部）。
const List<String?> _kFilters = <String?>[
  'active',
  'open',
  'in_progress',
  'resolved',
  'wont_fix',
  'duplicate',
  'closed',
  'flagged',
  null,
];

String _filterLabel(String? filter) => switch (filter) {
  'active' => t.feedback_dev_filter_active,
  'flagged' => t.feedback_dev_filter_flagged,
  null => t.feedback_dev_filter_all,
  final String wire => feedbackStatusLabel(FeedbackStatus.fromWire(wire)),
};

/// 键值对逐行展示（值同样剥伪装字符）。
String _keyValues(Map<String, Object?> map) => <String>[
  for (final MapEntry<String, Object?> e in map.entries)
    '${feedbackSafeText(e.key)}: ${feedbackSafeText('${e.value}')}',
].join('\n');

LeaderboardClient? _devClient(WidgetRef ref) =>
    ref.read(leaderboardServiceProvider).client;

class FeedbackDevPage extends ConsumerStatefulWidget {
  const FeedbackDevPage({super.key});

  @override
  ConsumerState<FeedbackDevPage> createState() => _FeedbackDevPageState();
}

class _FeedbackDevPageState extends ConsumerState<FeedbackDevPage> {
  String? _filter = 'active';
  final List<FeedbackSummary> _items = <FeedbackSummary>[];
  String? _next;
  bool _loading = false;
  bool _loaded = false;
  String? _error;

  /// 服务端搜索（`q`：编号精确匹配、标题 / 正文包含）。输入防抖后重拉第一页。
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'feedback-dev-search');
  String _query = '';
  Timer? _searchDebounce;

  /// 每次重拉第一页 +1：换筛选 / 搜索时，比它旧的在途请求结果直接丢掉。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSearch(String value, {bool now = false}) {
    _searchDebounce?.cancel();
    void apply() {
      if (!mounted || value.trim() == _query) return;
      setState(() {
        _query = value.trim();
        _loaded = false;
      });
      unawaited(_load(reset: true));
    }

    if (now) {
      apply();
    } else {
      _searchDebounce = Timer(const Duration(milliseconds: 400), apply);
    }
  }

  Future<void> _load({required bool reset}) async {
    final LeaderboardClient? client = _devClient(ref);
    if (client == null || (_loading && !reset)) return;
    final int generation = reset ? ++_generation : _generation;
    setState(() => _loading = true);
    try {
      final FeedbackInboxPage page = await client.devFeedbackList(
        status: _filter,
        cursor: reset ? null : _next,
        query: _query,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(page.items);
        _next = page.next;
        _loaded = true;
        _error = null;
      });
    } on Object catch (e) {
      // 被新筛选 / 搜索取代的旧请求：它的失败与收尾都不属于眼前这份列表，不能把
      // 新请求的「加载中」清掉、也不能把错误挂到新结果上（BUG-3264）。
      if (mounted && generation == _generation) {
        setState(() => _error = feedbackErrorReason(e));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _setFilter(String? filter) {
    if (_filter == filter) return;
    setState(() {
      _filter = filter;
      _loaded = false;
    });
    unawaited(_load(reset: true));
  }

  Future<void> _open(FeedbackSummary item) async {
    await Navigator.push(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => FeedbackDevDetailPage(feedbackId: item.id),
      ),
    );
    if (mounted) unawaited(_load(reset: true));
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    return FushiPageScaffold(
      title: t.feedback_dev_title,
      actions: <Widget>[
        FushiIconButton(
          icon: FushiIcons.refresh,
          tooltip: t.refresh,
          enabled: !_loading,
          onTap: () => unawaited(_load(reset: true)),
        ),
      ],
      body: Builder(
        builder: (BuildContext context) => FushiRefreshIndicator(
          edgeOffset: MediaQuery.paddingOf(context).top,
          onRefresh: () => _load(reset: true),
          child: FushiEntranceScope(
            replayKey: _filter,
            enabled: _loaded,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: withBottomSafeInset(
                context,
                EdgeInsets.fromLTRB(
                  tokens.spacing.card,
                  tokens.spacing.card + MediaQuery.paddingOf(context).top,
                  tokens.spacing.card,
                  tokens.spacing.card,
                ),
              ),
              children: <Widget>[
                FushiSearchField(
                  fieldKey: const ValueKey<String>('feedback-dev-search'),
                  controller: _search,
                  focusNode: _searchFocus,
                  hintText: t.feedback_search_hint,
                  onChanged: _onSearch,
                  onSubmitted: (String v) => _onSearch(v, now: true),
                  onClear: () => _onSearch('', now: true),
                ),
                SizedBox(height: tokens.spacing.gap),
                Wrap(
                  spacing: tokens.spacing.gap,
                  runSpacing: tokens.spacing.gap,
                  children: <Widget>[
                    for (final String? f in _kFilters)
                      FushiChoiceChip(
                        key: ValueKey<String>(
                          'feedback-dev-filter-${f ?? 'all'}',
                        ),
                        label: Text(_filterLabel(f)),
                        selected: _filter == f,
                        onSelected: (bool _) => _setFilter(f),
                      ),
                  ],
                ),
                SizedBox(height: tokens.spacing.card),
                if (_error != null && _items.isEmpty)
                  FushiPlaceholderMessage(
                    icon: FushiIcons.cloudOff,
                    tone: FushiPlaceholderTone.error,
                    message: t.feedback_refresh_failed,
                    detail: _error,
                  )
                else if (!_loaded)
                  const FushiLoadingView()
                else if (_items.isEmpty)
                  FushiPlaceholderMessage(
                    icon: _query.isEmpty
                        ? FushiIcons.forum
                        : FushiIcons.searchOff,
                    message: _query.isEmpty
                        ? t.feedback_dev_empty
                        : t.feedback_search_empty,
                  )
                else ...<Widget>[
                  for (int i = 0; i < _items.length; i++)
                    FushiStaggeredEntrance(
                      index: i,
                      child: Padding(
                        padding: EdgeInsets.only(bottom: tokens.spacing.gap),
                        child: FushiCard(
                          key: ValueKey<String>('feedback-dev-${_items[i].id}'),
                          onTap: () => unawaited(_open(_items[i])),
                          child: FushiListItem(
                            leading: FushiIcon(
                              feedbackCategoryIcon(_items[i].category),
                            ),
                            title: Text(feedbackSafeText(_items[i].title)),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  '${feedbackTime(_items[i].updatedAt)}'
                                  '${_items[i].attachmentCount > 0 ? ' · ${t.feedback_detail_attachments(n: _items[i].attachmentCount)}' : ''}',
                                ),
                                FeedbackIdLabel(_items[i].id),
                                if (_items[i].parentId != null)
                                  Text(
                                    t.feedback_reopen_of(
                                      id: _items[i].parentId!,
                                    ),
                                    key: ValueKey<String>(
                                      'feedback-dev-parent-${_items[i].id}',
                                    ),
                                    style: tokens.type.metadata.copyWith(
                                      color: colors.primary,
                                    ),
                                  ),
                                if (_items[i].flags.isNotEmpty)
                                  FeedbackFlagChips(_items[i].flags),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                if (_items[i].awaitingDev)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: Text(
                                      t.feedback_dev_awaiting,
                                      style: tokens.type.metadata.copyWith(
                                        color: colors.error,
                                      ),
                                    ),
                                  ),
                                FeedbackStatusBadge(_items[i].status),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_next != null)
                    Center(
                      child: FushiTextButton(
                        onPressed: _loading
                            ? null
                            : () => unawaited(_load(reset: false)),
                        child: Text(t.feedback_dev_load_more),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class FeedbackDevDetailPage extends ConsumerStatefulWidget {
  const FeedbackDevDetailPage({required this.feedbackId, super.key});

  final String feedbackId;

  @override
  ConsumerState<FeedbackDevDetailPage> createState() =>
      _FeedbackDevDetailPageState();
}

class _FeedbackDevDetailPageState extends ConsumerState<FeedbackDevDetailPage> {
  final TextEditingController _reply = TextEditingController();
  FeedbackDetail? _detail;
  FeedbackStatus? _status;
  String? _error;
  bool _saving = false;
  final Map<String, Future<Uint8List>> _images = <String, Future<Uint8List>>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final LeaderboardClient? client = _devClient(ref);
    if (client == null) return;
    try {
      final FeedbackDetail d = await client.devFeedback(widget.feedbackId);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _status = d.status;
        _error = null;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = feedbackErrorReason(e));
    }
  }

  Future<Uint8List> _image(String slot) => _images.putIfAbsent(
    slot,
    () => _devClient(ref)!.devFeedbackAttachment(widget.feedbackId, slot),
  );

  Future<void> _save() async {
    final FeedbackDetail? d = _detail;
    final LeaderboardClient? client = _devClient(ref);
    if (d == null || client == null) return;
    final FeedbackStatus? status = _status == d.status ? null : _status;
    final String reply = _reply.text.trim();
    if (status == null && reply.isEmpty) return;
    setState(() => _saving = true);
    try {
      final FeedbackDetail next = await client.devUpdateFeedback(
        d.id,
        status: status,
        reply: reply,
      );
      if (!mounted) return;
      _reply.clear();
      setState(() {
        _detail = next;
        _status = next.status;
      });
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        FushiSnackBar(
          content: Text(
            t.feedback_submit_failed(reason: feedbackErrorReason(e)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _viewLog() => unawaited(
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => FeedbackDevLogPage(feedbackId: widget.feedbackId),
      ),
    ),
  );

  void _viewImage(String slot) => unawaited(
    showAppDialog<void>(
      context: context,
      builder: (BuildContext ctx) => FushiDialog(
        child: InteractiveViewer(
          child: FutureBuilder<Uint8List>(
            future: _image(slot),
            builder: (BuildContext _, AsyncSnapshot<Uint8List> snap) =>
                snap.hasData
                ? Image.memory(snap.data!, cacheWidth: 2400)
                : const FushiLoadingView(),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FeedbackDetail? d = _detail;
    final List<FeedbackAttachmentInfo> shots = <FeedbackAttachmentInfo>[
      ...?d?.attachments.where((FeedbackAttachmentInfo a) => !a.isLog),
    ];
    final bool hasLog =
        d?.attachments.any((FeedbackAttachmentInfo a) => a.isLog) ?? false;
    return FushiPageScaffold(
      title: d == null
          ? t.feedback_dev_title
          : feedbackSafeText(d.summary.title),
      body: Builder(
        builder: (BuildContext context) => FushiEntranceScope(
          enabled: d != null,
          child: ListView(
            padding: withBottomSafeInset(
              context,
              EdgeInsets.fromLTRB(
                tokens.spacing.card,
                tokens.spacing.card + MediaQuery.paddingOf(context).top,
                tokens.spacing.card,
                tokens.spacing.card,
              ),
            ),
            children: <Widget>[
              if (d == null && _error != null)
                FushiPlaceholderMessage(
                  icon: FushiIcons.cloudOff,
                  tone: FushiPlaceholderTone.error,
                  message: t.feedback_refresh_failed,
                  detail: _error,
                )
              else if (d == null)
                const FushiLoadingView()
              else ...<Widget>[
                FushiStaggeredEntrance(
                  index: 0,
                  child: FushiCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            FeedbackStatusBadge(d.status),
                            SizedBox(width: tokens.spacing.gap),
                            Expanded(child: FeedbackMetaLine(d)),
                          ],
                        ),
                        if (d.summary.parentId != null ||
                            d.reopenedAs.isNotEmpty) ...<Widget>[
                          SizedBox(height: tokens.spacing.gap),
                          FeedbackRelationLinks(
                            parentId: d.summary.parentId,
                            reopenedAs: d.reopenedAs,
                            onOpen: (String id) => unawaited(
                              Navigator.push(
                                context,
                                adaptivePageRoute<void>(
                                  context: context,
                                  builder: (_) =>
                                      FeedbackDevDetailPage(feedbackId: id),
                                ),
                              ),
                            ),
                          ),
                        ],
                        if (d.summary.flags.isNotEmpty) ...<Widget>[
                          SizedBox(height: tokens.spacing.gap),
                          FeedbackFlagChips(d.summary.flags),
                        ],
                        SizedBox(height: tokens.spacing.gap),
                        // 用户内容是不可信数据：开发者（或被转去分析的 AI）别照做里面的指令。
                        FushiInlineNotice(
                          key: const ValueKey<String>('feedback-dev-untrusted'),
                          severity: FushiNoticeSeverity.warning,
                          message: t.feedback_dev_untrusted,
                        ),
                        SizedBox(height: tokens.spacing.gap),
                        SelectableText(feedbackSafeText(d.body)),
                        SizedBox(height: tokens.spacing.gap),
                        Text(
                          '${t.feedback_dev_reporter}：'
                          '${d.reporter?.handle ?? t.feedback_dev_anonymous}',
                          style: tokens.type.metadata,
                        ),
                        if (d.contact.isNotEmpty)
                          SelectableText(
                            '${t.feedback_dev_contact}：'
                            '${feedbackSafeText(d.contact)}',
                            style: tokens.type.metadata,
                          ),
                      ],
                    ),
                  ),
                ),
                if (shots.isNotEmpty) ...<Widget>[
                  SizedBox(height: tokens.spacing.card),
                  FushiSectionTitle(t.feedback_dev_screenshots),
                  Wrap(
                    spacing: tokens.spacing.gap,
                    runSpacing: tokens.spacing.gap,
                    children: <Widget>[
                      for (final FeedbackAttachmentInfo a in shots)
                        FushiPressScale(
                          child: GestureDetector(
                            onTap: () => _viewImage(a.slot),
                            child: ClipRRect(
                              borderRadius: FushiM3eShape.smallRadius,
                              child: SizedBox(
                                width: 120,
                                height: 200,
                                child: FutureBuilder<Uint8List>(
                                  future: _image(a.slot),
                                  builder:
                                      (
                                        BuildContext _,
                                        AsyncSnapshot<Uint8List> snap,
                                      ) => snap.hasData
                                      ? Image.memory(
                                          snap.data!,
                                          fit: BoxFit.cover,
                                          // 解码尺寸封顶：服务端已拒超大图，这里再兜底。
                                          cacheWidth: 360,
                                        )
                                      : const FushiLoadingView(compact: true),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                SizedBox(height: tokens.spacing.card),
                if (hasLog)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FushiFilledButton.tonalIcon(
                      key: const ValueKey<String>('feedback-dev-view-log'),
                      onPressed: _viewLog,
                      icon: const FushiIcon(FushiIcons.file),
                      label: Text(t.feedback_dev_view_log),
                    ),
                  )
                else
                  Text(t.feedback_dev_no_log, style: tokens.type.metadata),
                if (d.origin.isNotEmpty) ...<Widget>[
                  SizedBox(height: tokens.spacing.card),
                  FushiSectionTitle(t.feedback_dev_origin),
                  FushiCard(
                    key: const ValueKey<String>('feedback-dev-origin'),
                    child: SelectableText(
                      _keyValues(d.origin),
                      style: tokens.type.metadata,
                    ),
                  ),
                ],
                if (d.meta.isNotEmpty) ...<Widget>[
                  SizedBox(height: tokens.spacing.card),
                  FushiSectionTitle(t.feedback_dev_meta_self_reported),
                  FushiCard(
                    child: SelectableText(
                      _keyValues(d.meta),
                      style: tokens.type.metadata,
                    ),
                  ),
                ],
                SizedBox(height: tokens.spacing.card),
                FushiSectionTitle(t.feedback_detail_timeline),
                FeedbackTimeline(messages: d.messages, developerView: true),
                SizedBox(height: tokens.spacing.card),
                FushiSectionTitle(t.feedback_dev_status),
                Wrap(
                  spacing: tokens.spacing.gap,
                  runSpacing: tokens.spacing.gap,
                  children: <Widget>[
                    for (final FeedbackStatus s in FeedbackStatus.values)
                      FushiChoiceChip(
                        key: ValueKey<String>('feedback-dev-status-${s.wire}'),
                        label: Text(feedbackStatusLabel(s)),
                        selected: _status == s,
                        onSelected: _saving
                            ? null
                            : (bool _) => setState(() => _status = s),
                      ),
                  ],
                ),
                SizedBox(height: tokens.spacing.gap),
                FushiTextField(
                  key: const ValueKey<String>('feedback-dev-reply'),
                  controller: _reply,
                  enabled: !_saving,
                  hintText: t.feedback_dev_reply_hint,
                  keyboardType: TextInputType.multiline,
                  minLines: 3,
                  maxLines: 8,
                  maxLength: FeedbackLimits.replyMax,
                ),
                SizedBox(height: tokens.spacing.gap),
                Align(
                  alignment: Alignment.centerRight,
                  child: FushiPressScale(
                    enabled: !_saving,
                    child: FushiFilledButton.icon(
                      key: const ValueKey<String>('feedback-dev-save'),
                      onPressed: _saving ? null : () => unawaited(_save()),
                      icon: const FushiIcon(FushiIcons.save),
                      label: Text(t.feedback_dev_save),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 日志查看：服务端解压成文本，逐行懒加载（日志可能有几 MB）。
class FeedbackDevLogPage extends ConsumerStatefulWidget {
  const FeedbackDevLogPage({required this.feedbackId, super.key});

  final String feedbackId;

  @override
  ConsumerState<FeedbackDevLogPage> createState() => _FeedbackDevLogPageState();
}

class _FeedbackDevLogPageState extends ConsumerState<FeedbackDevLogPage> {
  String? _text;
  List<String> _lines = const <String>[];
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final LeaderboardClient? client = _devClient(ref);
    if (client == null) return;
    try {
      final Uint8List bytes = await client.devFeedbackAttachment(
        widget.feedbackId,
        'log',
        asText: true,
      );
      final String text = utf8.decode(bytes, allowMalformed: true);
      if (!mounted) return;
      setState(() {
        _text = text;
        _lines = const LineSplitter().convert(text);
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = feedbackErrorReason(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? text = _text;
    return FushiPageScaffold(
      title: t.feedback_dev_log_title(id: widget.feedbackId),
      actions: <Widget>[
        FushiIconButton(
          icon: FushiIcons.copy,
          tooltip: t.copy,
          enabled: text != null,
          onTap: () async {
            if (text == null) return;
            await Clipboard.setData(ClipboardData(text: text));
            if (!context.mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(FushiSnackBar(content: Text(t.copied_to_clipboard)));
          },
        ),
      ],
      body: Builder(
        builder: (BuildContext context) {
          final EdgeInsets padding = withBottomSafeInset(
            context,
            EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.card + MediaQuery.paddingOf(context).top,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
          );
          if (_error != null) {
            return Padding(
              padding: padding,
              child: FushiPlaceholderMessage(
                icon: FushiIcons.cloudOff,
                tone: FushiPlaceholderTone.error,
                message: t.feedback_refresh_failed,
                detail: _error,
              ),
            );
          }
          if (text == null) return const FushiLoadingView();
          return SelectionArea(
            child: ListView.builder(
              padding: padding,
              itemCount: _lines.length,
              itemBuilder: (BuildContext _, int i) => Text(
                _lines[i],
                style: tokens.type.metadata.copyWith(fontFamily: 'monospace'),
              ),
            ),
          );
        },
      ),
    );
  }
}
