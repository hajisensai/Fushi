/// 「AI 下载」页（浏览 › 发现的小说 / 漫画 / 游戏域；视频域另有对话式的
/// `ai_video_acquisition_page.dart`）。
///
/// 流程：一句话 →（AI）搜索词 →（本地）逐来源搜索 →（AI）在已取回的候选里挑
/// 推荐 → 用户点「下载」→（本地）按该条来源既有的下载路径入队 / 入库。AI 两步
/// 任一步失败都不挡流程：解析失败按原文搜，挑选失败按本地排序（做种数）列出。
/// AI 永远不直接触发下载。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';

import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart';
import 'package:fushi/src/media/acquisition/media_acquisition_backends.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/ai_settings_route.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';

/// 按域组装后端。[includeOnlineSources] 由浏览页按「来源」页签同一门
/// （模块开关 + 平台 / 合规）算好传入；漫画在线源另需 Mihon 运行时。
List<MediaAcquisitionBackend> mediaAcquisitionBackendsFor({
  required AppModel appModel,
  required AiMediaAcquisitionDomain domain,
  required bool includeOnlineSources,
}) => switch (domain) {
  AiMediaAcquisitionDomain.novel => <MediaAcquisitionBackend>[
    DiscoveryAcquisitionBackend(
      appModel: appModel,
      kinds: const <DiscoveryMediaKind>[
        DiscoveryMediaKind.novel,
        DiscoveryMediaKind.audiobook,
      ],
    ),
    if (includeOnlineSources)
      LnReaderNovelAcquisitionBackend(appModel: appModel),
  ],
  AiMediaAcquisitionDomain.manga => <MediaAcquisitionBackend>[
    if (includeOnlineSources && MihonRuntimeFactory.isSupported)
      MihonMangaAcquisitionBackend(appModel: appModel),
    DiscoveryAcquisitionBackend(
      appModel: appModel,
      kinds: const <DiscoveryMediaKind>[DiscoveryMediaKind.manga],
    ),
  ],
  AiMediaAcquisitionDomain.game => <MediaAcquisitionBackend>[
    DiscoveryAcquisitionBackend(
      appModel: appModel,
      kinds: const <DiscoveryMediaKind>[DiscoveryMediaKind.game],
    ),
  ],
};

/// 打开「AI 下载」页。未指派提供商时先引导去「设置 › AI」，配好了再继续。
Future<void> openAiMediaAcquisition(
  BuildContext context, {
  required AppModel appModel,
  required AiMediaAcquisitionDomain domain,
  required String domainLabel,
  required bool includeOnlineSources,
  String? initialQuery,
}) async {
  if (resolveMediaAcquireAiProvider(appModel.prefsRepo) == null) {
    FushiToast.show(msg: t.ai_assist_no_provider);
    await pushAiSettingsPage(context);
    if (!context.mounted ||
        resolveMediaAcquireAiProvider(appModel.prefsRepo) == null) {
      return;
    }
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext _) => AiMediaAcquisitionPage(
        domain: domain,
        domainLabel: domainLabel,
        initialQuery: initialQuery,
        ai: createPreferencesAiMediaAcquisitionAi(appModel.prefsRepo),
        backends: mediaAcquisitionBackendsFor(
          appModel: appModel,
          domain: domain,
          includeOnlineSources: includeOnlineSources,
        ),
      ),
    ),
  );
}

/// 候选按「AI 推荐在前（按推荐序），其余按本地分降序」排好。纯函数。
List<MediaAcquisitionCandidate> orderMediaAcquisitionCandidates(
  List<MediaAcquisitionCandidate> candidates,
  List<String> picks,
) {
  final Map<String, MediaAcquisitionCandidate> byId =
      <String, MediaAcquisitionCandidate>{
        for (final MediaAcquisitionCandidate c in candidates) c.id: c,
      };
  final List<MediaAcquisitionCandidate> picked = <MediaAcquisitionCandidate>[
    for (final String id in picks)
      if (byId[id] != null) byId[id]!,
  ];
  final Set<String> pickedIds = <String>{
    for (final MediaAcquisitionCandidate c in picked) c.id,
  };
  final List<MediaAcquisitionCandidate> rest =
      <MediaAcquisitionCandidate>[
        for (final MediaAcquisitionCandidate c in candidates)
          if (!pickedIds.contains(c.id)) c,
      ]..sort(
        (MediaAcquisitionCandidate a, MediaAcquisitionCandidate b) =>
            b.score.compareTo(a.score),
      );
  return <MediaAcquisitionCandidate>[...picked, ...rest];
}

enum _Phase { idle, parsing, searching, picking, done }

class AiMediaAcquisitionPage extends StatefulWidget {
  const AiMediaAcquisitionPage({
    super.key,
    required this.domain,
    required this.domainLabel,
    required this.ai,
    required this.backends,
    this.initialQuery,
  });

  final AiMediaAcquisitionDomain domain;
  final String domainLabel;
  final AiMediaAcquisitionAi ai;
  final List<MediaAcquisitionBackend> backends;
  final String? initialQuery;

  @override
  State<AiMediaAcquisitionPage> createState() => _AiMediaAcquisitionPageState();
}

class _AiMediaAcquisitionPageState extends State<AiMediaAcquisitionPage> {
  late final TextEditingController _input = TextEditingController(
    text: widget.initialQuery?.trim() ?? '',
  );
  _Phase _phase = _Phase.idle;
  List<String> _queries = const <String>[];
  List<MediaAcquisitionCandidate> _candidates =
      const <MediaAcquisitionCandidate>[];
  Set<String> _picks = const <String>{};
  bool _aiDegraded = false;

  /// 每次提交自增；旧一轮的回调看到代数变了就不再改页面。
  int _generation = 0;
  final Set<String> _acquiring = <String>{};
  final Set<String> _acquired = <String>{};

  @override
  void initState() {
    super.initState();
    if (_input.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_submit());
      });
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  bool get _busy =>
      _phase == _Phase.parsing ||
      _phase == _Phase.searching ||
      _phase == _Phase.picking;

  Future<void> _submit() async {
    final String utterance = _input.text.trim();
    if (utterance.isEmpty || _busy) return;
    final int generation = ++_generation;
    bool stale() => !mounted || generation != _generation;
    setState(() {
      _phase = _Phase.parsing;
      _queries = const <String>[];
      _candidates = const <MediaAcquisitionCandidate>[];
      _picks = const <String>{};
      _aiDegraded = false;
    });

    // ① 一句话 → 搜索词；失败 / 没解析出作品名就按原文搜。
    List<String> queries = <String>[utterance];
    try {
      final AiMediaAcquisitionIntent? intent = await widget.ai.parseIntent(
        widget.domain,
        utterance,
      );
      if (intent != null && !intent.isEmpty) queries = intent.queries;
    } on Object {
      _aiDegraded = true;
    }
    if (stale()) return;
    setState(() {
      _phase = _Phase.searching;
      _queries = queries;
    });

    // ② 逐词、全部后端并发搜，按 id 去重。
    final Map<String, MediaAcquisitionCandidate> found =
        <String, MediaAcquisitionCandidate>{};
    for (final String query in queries) {
      final List<List<MediaAcquisitionCandidate>> batches = await Future.wait(
        <Future<List<MediaAcquisitionCandidate>>>[
          for (final MediaAcquisitionBackend backend in widget.backends)
            backend
                .search(query)
                .catchError((Object _) => const <MediaAcquisitionCandidate>[]),
        ],
      );
      if (stale()) return;
      for (final List<MediaAcquisitionCandidate> batch in batches) {
        for (final MediaAcquisitionCandidate c in batch) {
          found.putIfAbsent(c.id, () => c);
        }
      }
      setState(() => _candidates = found.values.toList());
    }
    if (found.isEmpty) {
      setState(() => _phase = _Phase.done);
      return;
    }

    // ③ AI 在已取回的候选里挑推荐（池子按本地分截前 N）。
    setState(() => _phase = _Phase.picking);
    final List<MediaAcquisitionCandidate> pool =
        orderMediaAcquisitionCandidates(
          found.values.toList(),
          const <String>[],
        ).take(kAiMediaAcquisitionPickPool).toList();
    List<String> picks = const <String>[];
    try {
      picks =
          await widget.ai.pick(
            widget.domain,
            utterance,
            <AiMediaAcquisitionCandidateFact>[
              for (final MediaAcquisitionCandidate c in pool) c.toFact(),
            ],
          ) ??
          const <String>[];
    } on Object {
      _aiDegraded = true;
    }
    if (stale()) return;
    setState(() {
      _picks = picks.toSet();
      _candidates = orderMediaAcquisitionCandidates(
        found.values.toList(),
        picks,
      );
      _phase = _Phase.done;
    });
  }

  Future<void> _acquire(MediaAcquisitionCandidate candidate) async {
    if (!_acquiring.add(candidate.id)) return;
    setState(() {});
    try {
      final bool ok = await candidate.backend.acquire(context, candidate);
      if (ok) _acquired.add(candidate.id);
    } finally {
      _acquiring.remove(candidate.id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 统一页面壳（MD3 大标题 / Apple 大标题 + 玻璃返回钮），与其它子页一致。
    return FushiPageScaffold(
      title: t.ai_media_acquire_title(domain: widget.domainLabel),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    // 共享 M3E 搜索栏——这一栏就是「说一句话去搜」。
                    child: FushiSearchBar(
                      fieldKey: const ValueKey<String>(
                        'ai-media-acquire-input',
                      ),
                      controller: _input,
                      autofocus: widget.initialQuery?.trim().isEmpty ?? true,
                      hintText: t.ai_media_acquire_hint,
                      onSubmitted: (String _) => unawaited(_submit()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FushiFilledButton.icon(
                    key: const ValueKey<String>('ai-media-acquire-send'),
                    onPressed: _busy ? null : () => unawaited(_submit()),
                    icon: const FushiIcon(Icons.auto_awesome_outlined),
                    label: Text(t.ai_media_acquire_send),
                  ),
                ],
              ),
            ),
            if (_queries.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  t.ai_media_acquire_queries(queries: _queries.join(' / ')),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (_aiDegraded)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                // AI 降级是「仍可用、但没有智能推荐」的警告：统一提示块（中性底
                // + 单色警告图标），不再是一行红字像报错。
                child: FushiInlineNotice(
                  key: const ValueKey<String>('ai-media-acquire-degraded'),
                  severity: FushiNoticeSeverity.warning,
                  message: t.ai_media_acquire_ai_failed,
                ),
              ),
            if (_busy) ...<Widget>[
              const SizedBox(height: 8),
              const FushiLinearProgressIndicator(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Text(switch (_phase) {
                  _Phase.parsing => t.ai_media_acquire_parsing,
                  _Phase.picking => t.ai_media_acquire_picking,
                  _ => t.ai_media_acquire_searching,
                }, style: theme.textTheme.bodySmall),
              ),
            ],
            const SizedBox(height: 8),
            Expanded(child: _buildResults(theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    if (_phase == _Phase.done && _candidates.isEmpty) {
      return FushiPlaceholderMessage(
        key: const ValueKey<String>('ai-media-acquire-empty'),
        icon: Icons.search_off_rounded,
        message: t.ai_media_acquire_no_results,
      );
    }
    final List<MediaAcquisitionCandidate> picked = <MediaAcquisitionCandidate>[
      for (final MediaAcquisitionCandidate c in _candidates)
        if (_picks.contains(c.id)) c,
    ];
    final List<MediaAcquisitionCandidate> others = <MediaAcquisitionCandidate>[
      for (final MediaAcquisitionCandidate c in _candidates)
        if (!_picks.contains(c.id)) c,
    ];
    // 推荐 / 其它各是一个共享分组列表（MD3 分段卡 / Apple inset grouped），
    // 组标题缩进到行文字起点。
    const EdgeInsets groupPadding = EdgeInsets.symmetric(horizontal: 16);
    return ListView(
      key: const ValueKey<String>('ai-media-acquire-results'),
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        if (picked.isNotEmpty) ...<Widget>[
          _sectionLabel(theme, t.ai_media_acquire_recommended),
          FushiGroupedList(
            padding: groupPadding,
            children: <Widget>[
              for (final MediaAcquisitionCandidate c in picked)
                _candidateTile(theme, c, recommended: true),
            ],
          ),
        ],
        if (others.isNotEmpty && picked.isNotEmpty)
          _sectionLabel(theme, t.ai_media_acquire_others),
        if (others.isNotEmpty)
          FushiGroupedList(
            padding: groupPadding,
            children: <Widget>[
              for (final MediaAcquisitionCandidate c in others)
                _candidateTile(theme, c, recommended: false),
            ],
          ),
      ],
    );
  }

  // 分组标题（与设置分组同口径）：MD3 = titleSmall 主色 w600；Apple = 13 号
  // semibold secondaryLabel 灰字（inset grouped 的 section header 不上强调色）。
  Widget _sectionLabel(ThemeData theme, String label) => Padding(
    padding: const EdgeInsets.fromLTRB(32, 16, 32, 6),
    child: Text(
      label,
      style: isGlassDesign(context)
          ? settingsAppleSectionTitleStyle(context)
          : theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
    ),
  );

  Widget _candidateTile(
    ThemeData theme,
    MediaAcquisitionCandidate c, {
    required bool recommended,
  }) {
    final bool acquiring = _acquiring.contains(c.id);
    final bool acquired = _acquired.contains(c.id);
    final Widget action;
    if (acquiring) {
      action = const SizedBox.square(
        dimension: 24,
        child: FushiCircularProgressIndicator(strokeWidth: 2),
      );
    } else if (acquired) {
      action = FushiTooltip(
        message: t.ai_media_acquire_started,
        child: FushiIcon(Icons.check_circle, color: theme.colorScheme.primary),
      );
    } else if (recommended) {
      action = FushiFilledButton(
        onPressed: () => unawaited(_acquire(c)),
        child: Text(t.ai_media_acquire_download),
      );
    } else {
      action = FushiOutlinedButton(
        onPressed: () => unawaited(_acquire(c)),
        child: Text(t.ai_media_acquire_download),
      );
    }
    return FushiListItem(
      key: ValueKey<String>('ai-media-acquire-candidate-${c.id}'),
      leading: recommended
          ? FushiIcon(Icons.auto_awesome, color: theme.colorScheme.primary)
          : null,
      title: Text(c.title),
      titleMaxLines: 2,
      subtitle: Text(<String>[c.sourceLabel, ...c.details].join(' · ')),
      trailing: action,
    );
  }
}
