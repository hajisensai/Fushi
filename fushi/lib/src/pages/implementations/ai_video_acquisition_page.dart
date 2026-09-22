/// 「AI 下视频」对话页：气泡记录 + 当前问题的 chip + 底部输入框。
///
/// 页面**只渲染** [VideoAcquisitionService] 的状态，不含任何决策：问什么、什么时候提交
/// 都在 reducer 里；chip 点击直接落槽位（永不经 AI），文本才交给 AI 解析。文案全部
/// 从 [VideoAcquisitionSay] / 问题选项的 (slot, id) 取 i18n——AI 的输出里没有自由文本。
///
/// 不挂 Riverpod（与 `VideoDiscoveryResourceSearchPage` 同一姿态）：所有外部能力经
/// service 的端口注入，widget 测试不带 `ProviderScope` 直接 pump。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_service.dart';
import 'package:fushi/src/pages/implementations/ai_provider_settings_section.dart'
    show aiFailureText;
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart'
    show VideoDownloadBackendSetupPrompt;
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart'
    show VideoDownloadBackendUnavailable;
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show VideoDownloadPipelineActionRequired;
import 'package:fushi_engine/media/video/jimaku_client.dart'
    show jimakuLanguageLabel;

class AiVideoAcquisitionPage extends StatefulWidget {
  const AiVideoAcquisitionPage({
    required this.service,
    this.onConfigureBackend,
    super.key,
  });

  final VideoAcquisitionService service;

  /// 「去配置下载后端」端口；宿主没接线时失败态只报事实、不渲染按不动的按钮。
  final VideoDownloadBackendSetupPrompt? onConfigureBackend;

  @override
  State<AiVideoAcquisitionPage> createState() => _AiVideoAcquisitionPageState();
}

class _AiVideoAcquisitionPageState extends State<AiVideoAcquisitionPage> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode(debugLabel: 'ai-video-acquire-input');
  final ScrollController _scroll = ScrollController();
  StreamSubscription<VideoAcquisitionState>? _subscription;
  late VideoAcquisitionState _state = widget.service.state;

  /// 当前问题里「以后默认」勾选框的值（问题切换时重置为 `rememberDefault`）。
  bool _remember = true;
  VideoAcquisitionQuestion? _rememberFor;

  /// 已经用 SnackBar 报过的失败条目数，避免同一条 failed 重复弹。
  int _reportedFailures = 0;

  @override
  void initState() {
    super.initState();
    _subscription = widget.service.states.listen(_onState);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onState(VideoAcquisitionState state) {
    if (!mounted) return;
    setState(() => _state = state);
    _reportNewFailure(state);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// 失败气泡已经在记录里；SnackBar 只为给一颗**能解决它**的按钮（配置后端 / 重试）。
  void _reportNewFailure(VideoAcquisitionState state) {
    final int failures = state.transcript
        .whereType<VideoAcquisitionAssistantMessage>()
        .where(
          (VideoAcquisitionAssistantMessage m) =>
              m.say.kind == VideoAcquisitionSayKind.failed,
        )
        .length;
    if (failures <= _reportedFailures) return;
    _reportedFailures = failures;
    final Object? error = widget.service.lastError;
    SnackBarAction? action;
    String message = _sayText(
      state.transcript.whereType<VideoAcquisitionAssistantMessage>().last.say,
    );
    if (error is VideoDownloadBackendUnavailable) {
      action = _backendSetupAction();
    } else if (error is ArgumentError) {
      message = t.download_backend_not_configured;
      action = _backendSetupAction();
    } else if (error is VideoDownloadPipelineActionRequired) {
      action = SnackBarAction(
        label: t.retry,
        onPressed: () => unawaited(widget.service.confirm()),
      );
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
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
      VideoAcquisitionSayKind.submitted =>
        a['mode'] == VideoAcquisitionMode.subscribe.name
            ? t.ai_video_acquire_submitted_subscribe
            : t.ai_video_acquire_submitted_download(count: arg('count')),
      VideoAcquisitionSayKind.failed => t.ai_video_acquire_failed(
        message: arg('message'),
      ),
      VideoAcquisitionSayKind.cancelled => t.ai_video_acquire_cancelled,
      VideoAcquisitionSayKind.aiUnavailable =>
        t.ai_video_acquire_ai_unavailable(reason: aiFailureText(arg('code'))),
      VideoAcquisitionSayKind.unclear => t.ai_video_acquire_unclear,
      VideoAcquisitionSayKind.question => '',
    };
  }

  String _summaryText(Map<String, Object?> a) {
    final List<String> parts = <String>[
      if ('${a['releaseGroup'] ?? ''}'.isNotEmpty) '${a['releaseGroup']}',
      if ('${a['resolution'] ?? ''}'.isNotEmpty) '${a['resolution']}',
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
    final Object? missing = a['missing'];
    if (missing is List && missing.isNotEmpty) {
      return '$body\n${t.ai_video_acquire_summary_missing(episodes: missing.join(', '))}';
    }
    return body;
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
    }
    return switch (slot) {
      VideoAcquisitionSlot.mode || VideoAcquisitionSlot.subscribeFallback =>
        o.id == VideoAcquisitionMode.subscribe.name
            ? t.ai_video_acquire_option_subscribe
            : t.ai_video_acquire_option_download,
      VideoAcquisitionSlot.quality =>
        o.id == VideoAcquisitionQuality.any.storageKey
            ? t.ai_video_download_quality_any
            : o.id,
      VideoAcquisitionSlot.subtitleLanguage => _languageLabel(o.id),
      VideoAcquisitionSlot.season => 'S${o.id}',
      _ => o.id,
    };
  }

  String _languageLabel(String code) => switch (code) {
    kVideoAcquisitionSubtitleOriginal =>
      t.ai_video_download_subtitle_language_original,
    kVideoAcquisitionSubtitleNone => t.ai_video_download_subtitle_language_none,
    _ => jimakuLanguageLabel(code),
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
    if (question != _rememberFor) {
      _rememberFor = question;
      _remember = question?.rememberDefault ?? true;
    }
    final bool finished =
        _state.stage == VideoAcquisitionStage.done ||
        _state.stage == VideoAcquisitionStage.cancelled;
    return Scaffold(
      appBar: AppBar(title: Text(t.ai_video_acquire_title)),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListView(
                key: const ValueKey<String>('ai-video-acquire-transcript'),
                controller: _scroll,
                padding: EdgeInsets.symmetric(
                  horizontal: tokens.spacing.page,
                  vertical: tokens.spacing.gap,
                ),
                children: <Widget>[
                  if (_state.transcript.isEmpty)
                    _assistantBubble(
                      context,
                      Text(t.ai_video_acquire_greeting),
                    ),
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
                                    say.kind == VideoAcquisitionSayKind.question
                                ? _questionText(q)
                                : _sayText(say),
                          ),
                        ),
                    },
                  if (question != null && !finished)
                    _questionChips(context, question),
                  if (_state.busy)
                    Padding(
                      padding: EdgeInsets.only(top: tokens.spacing.gap),
                      child: const LinearProgressIndicator(
                        key: ValueKey<String>('ai-video-acquire-busy'),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            _composer(context, enabled: !finished && !_state.busy),
          ],
        ),
      ),
    );
  }

  /// 气泡走共享 [FushiCard]（圆角 / 表面色由设计令牌决定，页面不自定 MD3 决策）。
  Widget _userBubble(BuildContext context, String text) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: FushiCard(
        margin: const EdgeInsets.only(top: 8, left: 48),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        color: scheme.primaryContainer,
        child: Text(text, style: TextStyle(color: scheme.onPrimaryContainer)),
      ),
    );
  }

  Widget _assistantBubble(BuildContext context, Widget child) {
    return Align(
      alignment: Alignment.centerLeft,
      child: FushiCard(
        margin: const EdgeInsets.only(top: 8, right: 48),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: child,
      ),
    );
  }

  Widget _questionChips(BuildContext context, VideoAcquisitionQuestion q) {
    final List<Widget> chips = <Widget>[
      // hint 已经拼进 label，不再另套 Tooltip：hint 为空时那是一个悬停出空气泡的
      // 提示框，有 hint 时又是同一句话说两遍。
      for (int i = 0; i < q.options.length; i++)
        ActionChip(
          key: ValueKey<String>(
            'ai-video-acquire-option-${q.slot.name}-${q.options[i].id}',
          ),
          avatar: q.preselectedIndex == i
              ? const Icon(Icons.star_outline, size: 16)
              : null,
          label: Text(
            q.options[i].hint == null
                ? _optionLabel(q.slot, q.options[i])
                : '${_optionLabel(q.slot, q.options[i])} · ${q.options[i].hint}',
          ),
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
                  Checkbox(
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

  Widget _composer(BuildContext context, {required bool enabled}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              key: const ValueKey<String>('ai-video-acquire-input'),
              controller: _input,
              focusNode: _inputFocus,
              enabled: enabled,
              autofocus: true,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => unawaited(_send()),
              decoration: InputDecoration(
                hintText: t.ai_video_acquire_input_hint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          SizedBox(width: tokens.spacing.gap),
          IconButton.filled(
            key: const ValueKey<String>('ai-video-acquire-send'),
            tooltip: t.ai_video_acquire_send,
            onPressed: enabled ? () => unawaited(_send()) : null,
            icon: const Icon(Icons.send_rounded),
          ),
          SizedBox(width: tokens.spacing.gap),
          IconButton(
            key: const ValueKey<String>('ai-video-acquire-cancel'),
            tooltip: t.cancel,
            onPressed:
                _state.stage == VideoAcquisitionStage.done ||
                    _state.stage == VideoAcquisitionStage.cancelled
                ? () => Navigator.of(context).maybePop()
                : () => unawaited(widget.service.cancel()),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}
