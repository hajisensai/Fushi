/// 「AI 下视频」对话页：气泡记录 + 当前问题的 chip + 底部输入框。
///
/// 页面**只渲染** [VideoAcquisitionService] 的状态，不含任何决策：问什么、什么时候提交
/// 都在 reducer 里；chip 点击直接落槽位（永不经 AI），文本才交给 AI 解析。文案全部
/// 从 [VideoAcquisitionSay] / 问题选项的 (slot, id) 取 i18n——AI 的输出里没有自由文本。
///
/// 不挂 Riverpod（与 `VideoDiscoveryResourceSearchPage` 同一姿态）：所有外部能力经
/// service 的端口注入，widget 测试不带 `ProviderScope` 直接 pump。
///
/// 页面只认 [VideoAcquisitionSession] 与它的 [VideoAcquisitionView]：会话可以是本机
/// 的 `VideoAcquisitionService`，也可以是经互联交给电脑代办的远端会话（此时
/// [AiVideoAcquisitionPage.executorLabel] 是那台设备的名字，显示在标题下）。
library;

import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassTextField, LiquidRoundedSuperellipse;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show fushiFloatingPillDecoration;
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/media/discovery/discovery_labels.dart'
    show formatDiscoveryBytes;
import 'package:fushi_engine/media/video/acquisition/video_acquisition_reducer.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_view.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/pages/implementations/ai_provider_settings_section.dart'
    show aiFailureText;
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart'
    show VideoDownloadBackendSetupPrompt;
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart'
    show subtitleLanguageNativeName;

class AiVideoAcquisitionPage extends StatefulWidget {
  const AiVideoAcquisitionPage({
    required this.service,
    this.initialQuery,
    this.onConfigureBackend,
    this.executorLabel,
    super.key,
  });

  final VideoAcquisitionSession service;

  /// 入口处已经输入的文字（发现页搜索框）：非空就直接当第一句话发出去。
  final String? initialQuery;

  /// 「去配置下载后端」端口；宿主没接线时失败态只报事实、不渲染按不动的按钮。
  final VideoDownloadBackendSetupPrompt? onConfigureBackend;

  /// 会话交给了哪台设备执行（远端代办时非空）；null = 本机。
  final String? executorLabel;

  @override
  State<AiVideoAcquisitionPage> createState() => _AiVideoAcquisitionPageState();
}

class _AiVideoAcquisitionPageState extends State<AiVideoAcquisitionPage> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode(debugLabel: 'ai-video-acquire-input');
  final ScrollController _scroll = ScrollController();

  /// 浮在底部的输入栏占的高度（胶囊 + 上下留白）：对话列表底部留出这么多，
  /// 滚到底时最后一条消息落在输入栏上方。
  static const double _kComposerReserve = 84;
  StreamSubscription<VideoAcquisitionView>? _subscription;
  late VideoAcquisitionView _state = widget.service.view;

  /// 当前问题里「以后默认」勾选框的值（问题切换时重置为 `rememberDefault`）。
  /// 按问题的结构签名判断「切换」：远端会话每次更新都是新解码的对象，按对象身份
  /// 比会把用户刚改的勾选冲掉。
  bool _remember = true;
  String? _rememberFor;

  /// 已经用 SnackBar 报过的失败条目数，避免同一条 failed 重复弹。
  int _reportedFailures = 0;

  @override
  void initState() {
    super.initState();
    _subscription = widget.service.views.listen(_onState);
    final String initial = widget.initialQuery?.trim() ?? '';
    if (initial.isNotEmpty && widget.service.view.transcript.isEmpty) {
      unawaited(widget.service.submitText(initial));
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onState(VideoAcquisitionView state) {
    if (!mounted) return;
    setState(() => _state = state);
    _reportNewFailure(state);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// 失败气泡已经在记录里；SnackBar 只为给一颗**能解决它**的按钮（配置后端 / 重试）。
  void _reportNewFailure(VideoAcquisitionView state) {
    final int failures = state.transcript
        .whereType<VideoAcquisitionAssistantMessage>()
        .where(
          (VideoAcquisitionAssistantMessage m) =>
              m.say.kind == VideoAcquisitionSayKind.failed,
        )
        .length;
    if (failures <= _reportedFailures) return;
    _reportedFailures = failures;
    SnackBarAction? action;
    String message = _sayText(
      state.transcript.whereType<VideoAcquisitionAssistantMessage>().last.say,
    );
    switch (state.failureHint) {
      case VideoAcquisitionFailureHint.configureBackend:
        action = _backendSetupAction();
      case VideoAcquisitionFailureHint.backendNotConfigured:
        message = t.download_backend_not_configured;
        action = _backendSetupAction();
      case VideoAcquisitionFailureHint.retry:
        action = SnackBarAction(
          label: t.retry,
          onPressed: () => unawaited(widget.service.confirm()),
        );
      case VideoAcquisitionFailureHint.none:
        break;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      FushiSnackBar(
        content: Text(message),
        duration: const Duration(seconds: 10),
        action: action,
      ),
    );
  }

  SnackBarAction? _backendSetupAction() {
    final VideoDownloadBackendSetupPrompt? configure =
        widget.onConfigureBackend;
    if (configure == null) return null;
    return SnackBarAction(
      label: t.download_backend_setup_start,
      onPressed: () => unawaited(_configureBackendAndRetry(configure)),
    );
  }

  /// 配完后**自动重试提交**（与资源搜索页同一姿态）：用户点这个按钮的意图是「把这次
  /// 下载办成」；返回 false（没配完）或页面已卸载时不重试。
  Future<void> _configureBackendAndRetry(
    VideoDownloadBackendSetupPrompt configure,
  ) async {
    final bool configured = await configure(context);
    if (!configured || !mounted) return;
    await widget.service.confirm();
  }

  Future<void> _send() async {
    final String text = _input.text.trim();
    if (text.isEmpty || _state.busy) return;
    _input.clear();
    await widget.service.submitText(text);
    if (mounted) _inputFocus.requestFocus();
  }

  Future<void> _choose(VideoAcquisitionQuestion question, String optionId) =>
      widget.service.choose(
        question.slot,
        optionId,
        remember: question.rememberToggle ? _remember : null,
      );

  // ---------------------------------------------------------------------------
  // 文案
  // ---------------------------------------------------------------------------

  String _sayText(VideoAcquisitionSay say) {
    final Map<String, Object?> a = say.args;
    String arg(String key) => '${a[key] ?? ''}';
    return switch (say.kind) {
      VideoAcquisitionSayKind.greeting => t.ai_video_acquire_greeting,
      VideoAcquisitionSayKind.workNotFound => t.ai_video_acquire_work_not_found(
        query: arg('query'),
      ),
      VideoAcquisitionSayKind.workAliasResolved =>
        t.ai_video_acquire_work_alias_resolved(
          query: arg('query'),
          titles: arg('titles'),
        ),
      VideoAcquisitionSayKind.aiPicked => t.ai_video_acquire_ai_picked(
        title: arg('title'),
        confidence: _percent(a['confidence']),
      ),
      VideoAcquisitionSayKind.workChosen => t.ai_video_acquire_work_chosen(
        title: arg('title'),
      ),
      VideoAcquisitionSayKind.alreadyInLibrary =>
        a['highestEpisode'] == null
            ? t.ai_video_acquire_already_in_library(title: arg('title'))
            : t.ai_video_acquire_already_in_library_episode(
                title: arg('title'),
                episode: arg('highestEpisode'),
              ),
      VideoAcquisitionSayKind.alreadySubscribed =>
        t.ai_video_acquire_already_subscribed(title: arg('title')),
      VideoAcquisitionSayKind.airingUnknown =>
        t.ai_video_acquire_airing_unknown,
      VideoAcquisitionSayKind.subtitleLanguageResolved =>
        t.ai_video_acquire_subtitle_resolved(
          language: _languageLabel(arg('language')),
          evidence: _evidenceLabel(arg('evidence')),
        ),
      VideoAcquisitionSayKind.subtitleLanguageUnresolved =>
        t.ai_video_acquire_subtitle_unresolved,
      VideoAcquisitionSayKind.subtitleLanguageRemembered =>
        t.ai_video_acquire_subtitle_remembered(
          language: _languageLabel(arg('language')),
        ),
      VideoAcquisitionSayKind.summary => _summaryText(a),
      VideoAcquisitionSayKind.noMoreVersions =>
        t.ai_video_acquire_no_more_versions,
      VideoAcquisitionSayKind.recommendation => _recommendationText(a),
      VideoAcquisitionSayKind.submitted =>
        a['mode'] == VideoAcquisitionMode.subscribe.name
            ? t.ai_video_acquire_submitted_subscribe
            : t.ai_video_acquire_submitted_download(count: arg('count')),
      VideoAcquisitionSayKind.failed => t.ai_video_acquire_failed(
        message: _failureText(arg('message')),
      ),
      VideoAcquisitionSayKind.franchiseSearching =>
        t.ai_video_acquire_franchise_searching(title: arg('title')),
      VideoAcquisitionSayKind.franchiseFound =>
        t.ai_video_acquire_franchise_found(
          name: arg('name'),
          series: arg('series'),
          movies: arg('movies'),
        ),
      VideoAcquisitionSayKind.franchiseTruncated =>
        t.ai_video_acquire_franchise_truncated(name: arg('name')),
      VideoAcquisitionSayKind.franchiseProgress =>
        t.ai_video_acquire_franchise_progress(
          name: arg('name'),
          series: arg('series'),
          movies: arg('movies'),
        ),
      VideoAcquisitionSayKind.franchiseNotFound =>
        t.ai_video_acquire_franchise_not_found(title: arg('title')),
      VideoAcquisitionSayKind.franchiseUnavailable =>
        t.ai_video_acquire_franchise_unavailable(title: arg('title')),
      VideoAcquisitionSayKind.franchiseReady =>
        t.ai_video_acquire_franchise_ready(
          ready: arg('ready'),
          total: arg('total'),
        ),
      VideoAcquisitionSayKind.franchiseSubmitted =>
        t.ai_video_acquire_franchise_submitted(
          downloads: arg('downloads'),
          subscriptions: arg('subscriptions'),
          failed: arg('failed'),
        ),
      VideoAcquisitionSayKind.cancelled => t.ai_video_acquire_cancelled,
      VideoAcquisitionSayKind.aiUnavailable =>
        t.ai_video_acquire_ai_unavailable(reason: aiFailureText(arg('code'))),
      VideoAcquisitionSayKind.unclear => t.ai_video_acquire_unclear,
      VideoAcquisitionSayKind.question => '',
    };
  }

  /// reducer 的固定失败键翻成人话；其余（已脱敏的来源 / 后端消息）原样。
  String _failureText(String message) => switch (message) {
    kVideoAcquisitionFailureNoCandidates =>
      t.ai_video_acquire_failure_no_candidates,
    kVideoAcquisitionFailureNoPlannableVersion =>
      t.ai_video_acquire_failure_no_plannable_version,
    kVideoAcquisitionFailureNoSources => t.ai_video_acquire_failure_no_sources,
    kVideoAcquisitionFailureNothingSelected =>
      t.ai_video_acquire_failure_nothing_selected,
    kVideoAcquisitionFailureRemoteUnavailable =>
      t.ai_video_acquire_failure_remote_unavailable,
    _ => message,
  };

  /// 「哪个最好」的回答（BUG-2933）：理由（按偏好排序 / 按用户给的条件）与
  /// 结果（就是当前这个 / 已切换过去）两维正交，各一句模板。
  String _recommendationText(Map<String, Object?> a) {
    final String index = '${a['index'] ?? ''}';
    final bool current = a['current'] == true;
    if (a['byCriteria'] == true) {
      return current
          ? t.ai_video_acquire_recommend_criteria_current(index: index)
          : t.ai_video_acquire_recommend_criteria_switch(index: index);
    }
    return current
        ? t.ai_video_acquire_recommend_preference_current(index: index)
        : t.ai_video_acquire_recommend_preference_switch(index: index);
  }

  String _summaryText(Map<String, Object?> a) {
    final List<String> parts = <String>[
      if ('${a['releaseGroup'] ?? ''}'.isNotEmpty) '${a['releaseGroup']}',
      if ('${a['resolution'] ?? ''}'.isNotEmpty) '${a['resolution']}',
      if ('${a['source'] ?? ''}'.isNotEmpty) '${a['source']}',
      '${a['provider'] ?? ''}',
    ];
    final String body = a['batch'] == true
        ? t.ai_video_acquire_summary_batch(
            version: parts.join(' · '),
            seeders: '${a['seeders'] ?? 0}',
          )
        : t.ai_video_acquire_summary(
            version: parts.join(' · '),
            count: '${a['count'] ?? 0}',
            seeders: '${a['seeders'] ?? 0}',
          );
    final List<String> lines = <String>[
      body,
      <String>[
        if (a['total'] is int && (a['total']! as int) > 1)
          t.ai_video_acquire_summary_position(
            index: '${a['index']}',
            total: '${a['total']}',
          ),
        if (a['bytesPerEpisode'] is int)
          t.ai_video_acquire_summary_size(
            size: formatDiscoveryBytes(a['bytesPerEpisode']! as int),
          ),
      ].join(' · '),
    ];
    final Object? missing = a['missing'];
    if (missing is List && missing.isNotEmpty) {
      lines.add(
        t.ai_video_acquire_summary_missing(episodes: missing.join(', ')),
      );
    }
    return lines.where((String line) => line.isNotEmpty).join('\n');
  }

  String _questionText(VideoAcquisitionQuestion q) => switch (q.slot) {
    VideoAcquisitionSlot.work => t.ai_video_acquire_ask_work,
    VideoAcquisitionSlot.season => t.ai_video_acquire_ask_season,
    VideoAcquisitionSlot.mode => t.ai_video_acquire_ask_mode,
    VideoAcquisitionSlot.quality => t.ai_video_acquire_ask_quality,
    VideoAcquisitionSlot.subtitleLanguage =>
      t.ai_video_acquire_ask_subtitle_language,
    VideoAcquisitionSlot.targetSource => t.ai_video_acquire_ask_target_source,
    VideoAcquisitionSlot.resource => t.ai_video_acquire_ask_resource,
    VideoAcquisitionSlot.resolutionFallback =>
      t.ai_video_acquire_ask_resolution_fallback(
        wanted: '${q.args['wanted'] ?? ''}',
      ),
    VideoAcquisitionSlot.subscribeFallback =>
      t.ai_video_acquire_ask_subscribe_fallback,
    VideoAcquisitionSlot.presence => t.ai_video_acquire_ask_presence,
    // 清单卡上方已经有 franchiseReady 那句说明，问句本身不再重复。
    VideoAcquisitionSlot.franchise => '',
    VideoAcquisitionSlot.franchiseFallback =>
      t.ai_video_acquire_ask_franchise_fallback(
        title: '${q.args['title'] ?? ''}',
      ),
  };

  String _optionLabel(VideoAcquisitionSlot slot, VideoAcquisitionOption o) {
    if (o.label != null) return o.label!;
    switch (o.id) {
      case kVideoAcquisitionOptionConfirm:
        return t.ai_video_acquire_option_confirm;
      case kVideoAcquisitionOptionNext:
        return t.ai_video_acquire_option_next;
      case kVideoAcquisitionOptionCancel:
        return t.cancel;
      case kVideoAcquisitionOptionContinue:
        return t.ai_video_acquire_option_continue;
      case kVideoAcquisitionOptionNone:
        return t.ai_video_acquire_option_none;
      case kVideoAcquisitionOptionAll:
        return t.ai_video_acquire_option_all;
      case kVideoAcquisitionOptionLatest:
        return t.ai_video_acquire_option_latest;
      case kVideoAcquisitionOptionSubmitAll:
        return t.ai_video_acquire_option_submit_all(
          count:
              '${_state.franchise.where((VideoAcquisitionFranchiseRowView r) => r.submittable).length}',
        );
    }
    if (o.id.startsWith(kVideoAcquisitionOptionAltPrefix)) {
      return _alternativeLabel(o.id);
    }
    return switch (slot) {
      VideoAcquisitionSlot.mode || VideoAcquisitionSlot.subscribeFallback =>
        o.id == VideoAcquisitionMode.subscribe.name
            ? t.ai_video_acquire_option_subscribe
            : t.ai_video_acquire_option_download,
      VideoAcquisitionSlot.quality =>
        switch (VideoAcquisitionQuality.fromStorageKey(o.id)) {
          VideoAcquisitionQuality.best => t.ai_video_download_quality_best,
          VideoAcquisitionQuality.any => t.ai_video_download_quality_any,
          _ => o.id,
        },
      VideoAcquisitionSlot.subtitleLanguage => _languageLabel(o.id),
      VideoAcquisitionSlot.season => 'S${o.id}',
      _ => o.id,
    };
  }

  /// 候选版本 chip：`组 · 分辨率 · 片源 · 每集体积`（全是字面量事实，不翻译）。
  String _alternativeLabel(String optionId) {
    final int? index = int.tryParse(
      optionId.substring(kVideoAcquisitionOptionAltPrefix.length),
    );
    if (index == null ||
        index < 0 ||
        index >= _state.alternativeLabels.length) {
      return optionId;
    }
    return _state.alternativeLabels[index];
  }

  String _categoryLabel(VideoDiscoveryCategory category) => switch (category) {
    VideoDiscoveryCategory.movie => t.collection_relation_movie,
    VideoDiscoveryCategory.tv => t.series,
    VideoDiscoveryCategory.anime => t.media_tracking_anime,
  };

  /// 作品候选的副标题：reducer 给的年份 / 原名 + 这里翻译的类别。
  String? _workHint(VideoAcquisitionOption o) {
    final int? index = int.tryParse(o.id);
    if (index == null ||
        index < 0 ||
        index >= _state.workCandidateCategories.length) {
      return o.hint;
    }
    final VideoDiscoveryCategory? kind = _state.workCandidateCategories[index];
    if (kind == null) return o.hint;
    final String category = _categoryLabel(kind);
    return o.hint == null ? category : '${o.hint} · $category';
  }

  String _workActionLabel(String id) {
    if (id == kVideoAcquisitionOptionNone) {
      return t.ai_video_acquire_action_change_work;
    }
    return switch (VideoAcquisitionScope.fromStorageKey(
      id.substring(kVideoAcquisitionOptionScopePrefix.length),
    )) {
      VideoAcquisitionScope.franchise => t.ai_video_acquire_action_scope_all,
      VideoAcquisitionScope.franchiseMovies =>
        t.ai_video_acquire_action_scope_movies,
      VideoAcquisitionScope.franchiseSeries =>
        t.ai_video_acquire_action_scope_series,
      VideoAcquisitionScope.work => t.ai_video_acquire_action_scope_work,
      null => id,
    };
  }

  String _languageLabel(String code) => switch (code) {
    kVideoAcquisitionSubtitleOriginal =>
      t.ai_video_download_subtitle_language_original,
    kVideoAcquisitionSubtitleNone => t.ai_video_download_subtitle_language_none,
    _ => subtitleLanguageNativeName(code),
  };

  String _evidenceLabel(String evidence) => switch (evidence) {
    'originalLanguage' => t.ai_video_acquire_evidence_original_language,
    'countries' => t.ai_video_acquire_evidence_countries,
    'titleScript' => t.ai_video_acquire_evidence_title_script,
    _ => evidence,
  };

  static String _percent(Object? confidence) {
    final double value = switch (confidence) {
      num n => n.toDouble(),
      _ => 0,
    };
    return '${(value * 100).round()}%';
  }

  // ---------------------------------------------------------------------------
  // 渲染
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final VideoAcquisitionQuestion? question = _state.question;
    final String? questionKey = question == null
        ? null
        : '${question.slot.name}|'
              '${question.options.map((VideoAcquisitionOption o) => o.id).join(',')}|'
              '${_state.transcript.length}';
    if (questionKey != _rememberFor) {
      _rememberFor = questionKey;
      _remember = question?.rememberDefault ?? true;
    }
    final bool finished = _state.finished;
    final bool submitting = _state.stage == VideoAcquisitionStage.submitting;
    // 提交在飞时不许退出：返回会让用户以为「没下」，而入队仍在后台继续。
    return PopScope(
      canPop: !submitting,
      // 统一页面壳：M3E 浮动页头 / Apple 大标题；远端代办时执行设备作副标题。
      child: FushiPageScaffold(
        title: t.ai_video_acquire_title,
        subtitle: widget.executorLabel == null
            ? null
            : t.ai_video_acquire_remote_executor(device: widget.executorLabel!),
        // 对话流铺满整页，输入栏浮在底部（iOS 26 Messages：玻璃胶囊压在气泡上；
        // M3E：浮起的输入胶囊工具条）。列表底部留出输入栏的高度，最后一条消息
        // 不会被压住。
        body: SafeArea(
          top: false,
          bottom: false,
          child: Stack(
            children: <Widget>[
              // 页头浮在对话流上（脚手架默认 extendBodyBehindHeader）：顶部让位
              // 从 body 子树的 context 读（State 的 context 在脚手架之上）。
              Positioned.fill(
                child: Builder(
                  builder: (BuildContext bodyContext) => ListView(
                  key: const ValueKey<String>('ai-video-acquire-transcript'),
                  controller: _scroll,
                  padding: EdgeInsets.fromLTRB(
                    tokens.spacing.page,
                    tokens.spacing.gap + MediaQuery.paddingOf(bodyContext).top,
                    tokens.spacing.page,
                    _kComposerReserve + bottomSafeInsetOf(context),
                  ),
                  children: <Widget>[
                    if (_state.transcript.isEmpty) ...<Widget>[
                      _greetingHeader(context),
                      _assistantBubble(
                        context,
                        Text(t.ai_video_acquire_greeting),
                      ),
                    ],
                    for (final VideoAcquisitionMessage message
                        in _state.transcript)
                      switch (message) {
                        VideoAcquisitionUserMessage(:final String text) =>
                          _userBubble(context, text),
                        VideoAcquisitionAssistantMessage(
                          :final VideoAcquisitionSay say,
                          question: final VideoAcquisitionQuestion? q,
                        ) =>
                          _assistantBubble(
                            context,
                            Text(
                              q != null &&
                                      say.kind ==
                                          VideoAcquisitionSayKind.question
                                  ? _questionText(q)
                                  : _sayText(say),
                            ),
                          ),
                      },
                    if (_state.franchise.isNotEmpty) _franchiseCard(context),
                    if (question != null && !finished)
                      _questionChips(context, question),
                    if (_state.workActions.isNotEmpty) _workActions(context),
                    if (finished)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FushiActionChipControl(
                            key: const ValueKey<String>(
                              'ai-video-acquire-restart',
                            ),
                            avatar: const FushiIcon(FushiIcons.add, size: 16),
                            label: Text(t.ai_video_acquire_restart),
                            onPressed: () =>
                                unawaited(widget.service.restart()),
                          ),
                        ),
                      ),
                    if (_state.busy)
                      FushiStaggeredEntrance(
                        index: 0,
                        child: Padding(
                          padding: EdgeInsets.only(top: tokens.spacing.gap),
                          child: const FushiLinearProgressIndicator(
                            key: ValueKey<String>('ai-video-acquire-busy'),
                          ),
                        ),
                      ),
                  ],
                ),
                ),
              ),
              // 结束后照样能打字：直接说下一部就是「再下一部」。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _composer(context, enabled: !_state.busy),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _userBubble(BuildContext context, String text) =>
      _bubble(context, fromUser: true, child: Text(text));

  Widget _assistantBubble(BuildContext context, Widget child) =>
      _bubble(context, fromUser: false, child: child);

  /// 聊天气泡（内容层实色，不是玻璃）：
  /// - MD3：用户 = primaryContainer、AI = surfaceContainerHigh；
  /// - Apple（iMessage）：用户 = 强调色实底 + onAccent、AI = secondarySystemFill
  ///   + label；
  /// - 墨水屏：不靠底色区分（灰阶下塌掉），改用前景色细描边。
  ///
  /// 大圆角，发送方那一侧的下角收小，读作「从这一边说出来」；宽度最多占
  /// 内容区 78%，长句换行而不是横贯全屏。
  Widget _bubble(
    BuildContext context, {
    required bool fromUser,
    required Widget child,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool glass = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final Color fill;
    final Color foreground;
    if (eink) {
      fill = scheme.surface;
      foreground = scheme.onSurface;
    } else if (glass) {
      fill = fromUser ? apple.accent : apple.secondaryFill;
      foreground = fromUser ? apple.onAccent : apple.label;
    } else {
      fill = fromUser ? scheme.primaryContainer : scheme.surfaceContainerHigh;
      foreground = fromUser ? scheme.onPrimaryContainer : scheme.onSurface;
    }
    const Radius big = Radius.circular(24);
    const Radius tail = Radius.circular(6);
    final double maxWidth = MediaQuery.sizeOf(context).width * 0.78;
    // 新消息挂载时弹入（淡入 + 弹簧上移）；已显示的气泡 rebuild 不重播。
    // 不包 FushiEntranceScope：窗口常开，对话里每条新消息都该有进场。
    return FushiStaggeredEntrance(
      index: 0,
      child: _bubbleBody(
        context,
        fromUser: fromUser,
        fill: fill,
        foreground: foreground,
        border: eink ? Border.all(color: scheme.onSurface) : null,
        big: big,
        tail: tail,
        maxWidth: maxWidth,
        child: child,
      ),
    );
  }

  Widget _bubbleBody(
    BuildContext context, {
    required bool fromUser,
    required Widget child,
    required Color fill,
    required Color foreground,
    required Border? border,
    required Radius big,
    required Radius tail,
    required double maxWidth,
  }) {
    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth < 640 ? maxWidth : 640),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.only(
                topLeft: big,
                topRight: big,
                bottomLeft: fromUser ? big : tail,
                bottomRight: fromUser ? tail : big,
              ),
              border: border,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: DefaultTextStyle.merge(
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: foreground,
                  height: 1.35,
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _questionChips(BuildContext context, VideoAcquisitionQuestion q) {
    final List<Widget> chips = <Widget>[
      // hint 已经拼进 label，不再另套 Tooltip：hint 为空时那是一个悬停出空气泡的
      // 提示框，有 hint 时又是同一句话说两遍。
      for (int i = 0; i < q.options.length; i++)
        FushiActionChipControl(
          key: ValueKey<String>(
            'ai-video-acquire-option-${q.slot.name}-${q.options[i].id}',
          ),
          avatar: q.preselectedIndex == i
              ? const FushiIcon(FushiIcons.star, size: 16)
              : null,
          label: Text(switch (q.slot == VideoAcquisitionSlot.work
              ? _workHint(q.options[i])
              : q.options[i].hint) {
            null => _optionLabel(q.slot, q.options[i]),
            final String hint =>
              '${_optionLabel(q.slot, q.options[i])} · $hint',
          }),
          onPressed: _state.busy
              ? null
              : () => unawaited(_choose(q, q.options[i].id)),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(spacing: 8, runSpacing: 8, children: chips),
          if (q.rememberToggle)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  FushiCheckbox(
                    key: const ValueKey<String>('ai-video-acquire-remember'),
                    value: _remember,
                    onChanged: (bool? value) =>
                        setState(() => _remember = value ?? false),
                  ),
                  Text(t.ai_video_acquire_remember_default),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 作品操作条：换一部 / 整个系列 / 全部剧场版…（非阻塞，提交前一直可点）。
  Widget _workActions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final String id in _state.workActions)
            FushiActionChipControl(
              key: ValueKey<String>('ai-video-acquire-action-$id'),
              avatar: FushiIcon(
                id == kVideoAcquisitionOptionNone
                    ? FushiIcons.swap
                    : FushiIcons.collection,
                size: 16,
              ),
              label: Text(_workActionLabel(id)),
              onPressed: () => unawaited(
                widget.service.choose(VideoAcquisitionSlot.work, id),
              ),
            ),
        ],
      ),
    );
  }

  /// 整套清单：每部一行，勾选框只在清单就绪后能动；未找到资源的行灰掉。
  Widget _franchiseCard(BuildContext context) {
    final bool editable =
        _state.stage == VideoAcquisitionStage.awaitingFranchiseConfirm &&
        !_state.busy;
    final List<VideoAcquisitionFranchiseRowView> entries = _state.franchise;
    // 共享分组列表（MD3 分段卡 / Apple inset grouped），每部一行。
    return FushiGroupedList(
      key: const ValueKey<String>('ai-video-acquire-franchise'),
      padding: const EdgeInsets.only(top: 8),
      children: <Widget>[
        for (int i = 0; i < entries.length; i++)
          _franchiseRow(
            index: i,
            entry: entries[i],
            toggle:
                editable &&
                    entries[i].status ==
                        VideoAcquisitionFranchiseEntryStatus.ready
                ? () => unawaited(widget.service.toggleFranchiseEntry(i))
                : null,
          ),
      ],
    );
  }

  Widget _franchiseRow({
    required int index,
    required VideoAcquisitionFranchiseRowView entry,
    required VoidCallback? toggle,
  }) {
    return FushiListItem(
      key: ValueKey<String>('ai-video-acquire-franchise-$index'),
      density: FushiListDensity.compact,
      leading: FushiCheckbox(
        value: entry.selected,
        onChanged: toggle == null ? null : (_) => toggle(),
      ),
      title: Text(_franchiseTitle(entry)),
      subtitle: Text(_franchiseStatus(entry)),
      onTap: toggle,
    );
  }

  String _franchiseTitle(VideoAcquisitionFranchiseRowView entry) =>
      entry.year == null ? entry.title : '${entry.title} (${entry.year})';

  String _franchiseStatus(VideoAcquisitionFranchiseRowView entry) {
    final String status = switch (entry.status) {
      VideoAcquisitionFranchiseEntryStatus.pending =>
        t.ai_video_acquire_franchise_entry_pending,
      VideoAcquisitionFranchiseEntryStatus.noResource =>
        t.ai_video_acquire_franchise_entry_none,
      VideoAcquisitionFranchiseEntryStatus.ready => switch (entry.mode) {
        VideoAcquisitionMode.download =>
          t.ai_video_acquire_franchise_entry_download(
            version: entry.versionLabel ?? '',
          ),
        VideoAcquisitionMode.subscribe =>
          t.ai_video_acquire_franchise_entry_subscribe(
            version: entry.versionLabel ?? '',
          ),
      },
    };
    return entry.owned
        ? '$status · ${t.ai_video_acquire_franchise_entry_owned}'
        : status;
  }

  /// 底部输入栏：
  /// - Apple（iOS 26 Messages）：无色透明液态玻璃胶囊浮在对话上，栏本身无底；
  /// - MD3：页面底色的输入条里一枚填充式胶囊（surfaceContainerHigh，无描边）。
  /// 发送是实心圆钮，取消是普通圆钮。
  Widget _composer(BuildContext context, {required bool enabled}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool glass = isGlassDesign(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? inputStyle = Theme.of(context).textTheme.bodyLarge;
    final Widget input = glass
        ? GlassTextField(
            key: const ValueKey<String>('ai-video-acquire-input'),
            controller: _input,
            focusNode: _inputFocus,
            enabled: enabled,
            autofocus: true,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => unawaited(_send()),
            placeholder: t.ai_video_acquire_input_hint,
            textStyle: inputStyle?.copyWith(
              color: appleColorsOf(context).label,
            ),
            placeholderStyle: inputStyle?.copyWith(
              color: appleColorsOf(context).tertiaryLabel,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            shape: const LiquidRoundedSuperellipse(borderRadius: 22),
            settings: fushiClearGlassSettings(context, bar: true),
            quality: fushiGlassQuality(context),
            useOwnLayer: true,
          )
        : DecoratedBox(
            decoration: BoxDecoration(
              color: isEinkTheme(context)
                  ? scheme.surface
                  : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(28),
              border: isEinkTheme(context)
                  ? Border.all(color: scheme.onSurface)
                  : null,
            ),
            child: FushiTextFieldControl(
              key: const ValueKey<String>('ai-video-acquire-input'),
              controller: _input,
              focusNode: _inputFocus,
              enabled: enabled,
              autofocus: true,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => unawaited(_send()),
              style: inputStyle,
              decoration: InputDecoration(
                hintText: t.ai_video_acquire_input_hint,
                // 胶囊由外层 DecoratedBox 画；输入框本身无边框无填充。
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
              ),
            ),
          );
    final Widget row = Row(
          children: <Widget>[
            Expanded(child: input),
            SizedBox(width: tokens.spacing.gap),
            FushiIconButtonControl.filled(
              key: const ValueKey<String>('ai-video-acquire-send'),
              tooltip: t.ai_video_acquire_send,
              onPressed: enabled ? () => unawaited(_send()) : null,
              icon: FushiIcon(
                glass ? CupertinoIcons.arrow_up : FushiIcons.forward,
              ),
            ),
          SizedBox(width: tokens.spacing.gap),
            FushiIconButtonControl(
              key: const ValueKey<String>('ai-video-acquire-cancel'),
              tooltip: t.cancel,
              onPressed: switch (_state.stage) {
                // 提交在飞：取消不了（reducer 同样不接），按钮禁用而不是假装取消。
                VideoAcquisitionStage.submitting => null,
                VideoAcquisitionStage.done || VideoAcquisitionStage.cancelled =>
                  () => Navigator.of(context).maybePop(),
                _ => () => unawaited(widget.service.cancel()),
              },
              icon: const FushiIcon(FushiIcons.close),
            ),
          ],
        );
    final EdgeInsets outer = EdgeInsets.fromLTRB(
      tokens.spacing.page,
      tokens.spacing.gap,
      tokens.spacing.page,
      tokens.spacing.gap + tokens.spacing.gap / 2 + bottomSafeInsetOf(context),
    );
    // Apple：玻璃胶囊直接压在对话上；墨水屏：页面底色托住；M3E：浮起的
    // 工具条胶囊（与浮动页头同一套 pill 装饰），对话从它下面滚过。
    if (glass) return Padding(padding: outer, child: row);
    if (isEinkTheme(context)) {
      return ColoredBox(
        color: scheme.surface,
        child: Padding(padding: outer, child: row),
      );
    }
    return Padding(
      padding: outer,
      child: DecoratedBox(
        decoration: fushiFloatingPillDecoration(
          context,
          color: scheme.surfaceContainer,
        ),
        child: Padding(padding: const EdgeInsets.all(6), child: row),
      ),
    );
  }

  /// 空对话时气泡上方的引导头：cookie 形 AI 色块 + 标题（M3E 饱和色块；
  /// Apple 走强调色方块）。
  Widget _greetingHeader(BuildContext context) {
    return FushiStaggeredEntrance(
      index: 0,
      child: Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Row(
          children: <Widget>[
            const FushiListLeadingIcon(
              FushiIcons.ai,
              shape: FushiLeadingShape.cookie,
              tone: FushiCardTone.primary,
              size: 48,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                t.ai_video_acquire_title,
                style: context.fushiType.titleLargeEmphasized,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
