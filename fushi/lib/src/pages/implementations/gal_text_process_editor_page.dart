/// galgame 文本处理管线的可视化编辑页。
///
/// UI 范式照抄本仓既有的两个可视化编辑器（`lib/src/anki/lapis_style_editor_page.dart`
/// 与 `dictionary_settings_dialog_page.dart` 的可视化标签页）：左侧活预览 + 右侧 340 宽
/// 控件列，820 断点以下降级成上下两段；**草稿态全在本 State 里，边改边刷新预览，只有点
/// 「保存」才落盘**；脏了才亮保存按钮；返回时拦一次「放弃未保存修改」。
///
/// 与那两个编辑器唯一的结构差别在预览：它们用 WebView 渲染样式，这里渲染的是
/// [GalTextProcessPipeline.run] 的**逐步留痕**——每一步吃进什么、吐出什么、有没有把整行
/// 清空，是用户判断「这条规则该不该留」的唯一依据。预览与 hook 热路径共用同一份
/// [applyGalTextProcessStep]，预览结果与真实入库文本不可能分叉。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_text_process_assistant.dart';
import 'package:fushi/src/mining/galgame_text_process.dart';
import 'package:fushi/utils.dart';

/// 取「当前所选线程最近抓到的一行」。返回空串 = 拿不到（未选线程 / 该线程还没出过文本），
/// 页面据此把「使用最近抓到的一行」按钮置灰。
typedef GalTextProcessSampleProvider = String Function();

/// 解析本功能当前可用的 AI 提供商。返回 null = 没配 / 配的那家已被删或没配全，
/// 页面据此提示去设置里配，而**不发请求**。
///
/// 做成回调而不是在页面内读偏好，是为了让本页零 Riverpod 依赖：它是 push 出来的独立
/// 路由，widget 测试里不必挂 `ProviderScope`（挂了反而会把 AppModel 的初始化拖进来）。
typedef GalTextProcessAiProviderResolver = AiProviderConfig? Function();

/// 造 AI 调用客户端。测试注入假 `http.Client` 走这条缝；生产路径恒是 [AiChatClient]
/// 的默认构造（内部走 `createAppHttpIoClient()`），本页不允许裸 new 一个 http 客户端。
typedef GalTextProcessAiClientFactory = AiChatClient Function();

/// 宽屏左右分栏的断点（与 `LapisStyleEditorPage` 同值）。
const double _kWideBreakpoint = 820;

/// 控件列固定宽度（同上）。
const double _kControlsWidth = 340;

/// 窄屏降级布局里预览段的高度。
const double _kNarrowPreviewHeight = 300;

/// 文本为空时的占位字符——预览里「这一步把行清空了」必须看得见，留白看起来像没渲染。
const String _kEmptyGlyph = '—';

class GalTextProcessEditorPage extends StatefulWidget {
  const GalTextProcessEditorPage({
    required this.initialPipeline,
    required this.onSave,
    super.key,
    this.latestSample,
    this.resolveAiProvider,
    this.aiClientFactory,
  });

  /// 进页面时生效的管线（来自 `GalHookSessionController.textProcessPipeline`）。
  final GalTextProcessPipeline initialPipeline;

  /// 点「保存」时回调一次。**只有这一条落盘路径**——拖动重排、改参数、AI 追加步骤全都
  /// 只改草稿，不写盘（否则「取消」撤不回已经生效过的中间态）。
  final ValueChanged<GalTextProcessPipeline> onSave;

  final GalTextProcessSampleProvider? latestSample;
  final GalTextProcessAiProviderResolver? resolveAiProvider;

  @visibleForTesting
  final GalTextProcessAiClientFactory? aiClientFactory;

  @override
  State<GalTextProcessEditorPage> createState() =>
      _GalTextProcessEditorPageState();
}

class _GalTextProcessEditorPageState extends State<GalTextProcessEditorPage> {
  late List<GalTextProcessStep> _steps;
  late final TextEditingController _sampleController;
  final TextEditingController _aiRequestController = TextEditingController();

  /// AI 区的一句话状态（已加 N 步 / 没配提供商 / 失败原因）。null = 还没跑过。
  String? _aiMessage;

  /// AI 对自己这组规则的说明，原样显示。
  String _aiExplanation = '';
  bool _aiBusy = false;
  bool _allowPop = false;

  @override
  void initState() {
    super.initState();
    _steps = List<GalTextProcessStep>.of(widget.initialPipeline.steps);
    _sampleController = TextEditingController(
      text: widget.latestSample?.call() ?? '',
    );
  }

  @override
  void dispose() {
    _sampleController.dispose();
    _aiRequestController.dispose();
    super.dispose();
  }

  /// 当前草稿。`withSteps` 会拷成 unmodifiable，拿到的永远是快照。
  GalTextProcessPipeline get _draftPipeline =>
      const GalTextProcessPipeline().withSteps(_steps);

  bool get _isDirty => _draftPipeline != widget.initialPipeline;

  String get _sample => _sampleController.text;

  /// 自动去重（`repeatCount == null`）会打断渐进重绘折叠——同一句可能在工作台留多条。
  /// 只看**启用**的步骤：关掉的步骤跑都不跑，为它告警等于制造噪音。
  bool get _hasAutoDedupe => _steps.any(
    (GalTextProcessStep step) =>
        step.enabled &&
        step.repeatCount == null &&
        (step.kind == GalTextProcessKind.dedupeChars ||
            step.kind == GalTextProcessKind.dedupeBlockFixed),
  );

  /// 这两步会删掉注音标记的载体，而注音解析（`parseRubyMarkup`）跑在管线**之后**，
  /// 被删过的行从此没有振假名。
  bool get _hasRubyRisk => _steps.any(
    (GalTextProcessStep step) =>
        step.enabled &&
        (step.kind == GalTextProcessKind.stripAngleBrackets ||
            step.kind == GalTextProcessKind.filterAsciiPunctuation),
  );

  // ── 草稿编辑 ──────────────────────────────────────────────────────────────

  void _replaceSteps(List<GalTextProcessStep> next) =>
      setState(() => _steps = next);

  void _updateStep(
    String id,
    GalTextProcessStep Function(GalTextProcessStep step) update,
  ) => _replaceSteps(<GalTextProcessStep>[
    for (final GalTextProcessStep step in _steps)
      if (step.id == id) update(step) else step,
  ]);

  void _removeStep(String id) => _replaceSteps(<GalTextProcessStep>[
    for (final GalTextProcessStep step in _steps)
      if (step.id != id) step,
  ]);

  void _addStep(GalTextProcessKind kind) {
    // id 必须在**当前草稿**内唯一，所以先取 id 再改列表。
    final String id = _draftPipeline.nextIdFor(kind);
    _replaceSteps(<GalTextProcessStep>[
      ..._steps,
      GalTextProcessStep(id: id, kind: kind),
    ]);
  }

  /// 「item[from] 移到最终下标 to」——[FushiReorderableColumn] 的契约。
  void _reorder(int from, int to) {
    final List<GalTextProcessStep> next = List<GalTextProcessStep>.of(_steps);
    final GalTextProcessStep moved = next.removeAt(from);
    next.insert(to, moved);
    _replaceSteps(next);
  }

  void _useLatestSample() {
    final String latest = widget.latestSample?.call() ?? '';
    if (latest.isEmpty) return;
    setState(() => _sampleController.text = latest);
  }

  // ── 保存 / 返回 ──────────────────────────────────────────────────────────

  void _save() {
    widget.onSave(_draftPipeline);
    _pop();
  }

  void _pop() {
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _attemptClose() async {
    if (!_isDirty) {
      _pop();
      return;
    }
    final bool? discard = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(t.book_css_editor_unsaved_changes),
        content: Text(t.book_css_editor_unsaved_changes_message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(t.book_css_editor_discard),
          ),
        ],
      ),
    );
    if (discard == true) _pop();
  }

  // ── AI 生成 ──────────────────────────────────────────────────────────────

  Future<void> _runAi() async {
    if (_aiBusy) return;
    final String request = _aiRequestController.text.trim();
    if (request.isEmpty) return;
    final AiProviderConfig? provider = widget.resolveAiProvider?.call();
    if (provider == null) {
      // 没有可用提供商就**一个请求都不发**：发出去只会拿回一条脱敏错误码，用户还得
      // 自己猜「是 key 错了还是根本没配」。
      setState(() {
        _aiMessage = t.game_text_process_ai_no_provider;
        _aiExplanation = '';
      });
      return;
    }
    setState(() {
      _aiBusy = true;
      _aiMessage = null;
      _aiExplanation = '';
    });
    final AiChatClient client =
        widget.aiClientFactory?.call() ?? AiChatClient();
    try {
      final GalTextProcessPipeline draft = _draftPipeline;
      final AiTextProcessSuggestion suggestion =
          await requestAiTextProcessSteps(
            client: client,
            provider: provider,
            request: request,
            into: draft,
            sampleText: _sample,
            currentOutput: draft.apply(_sample),
          );
      if (!mounted) return;
      if (suggestion.isEmpty) {
        setState(() => _aiMessage = t.game_text_process_ai_empty);
        return;
      }
      // 追加进**草稿**，不落盘：AI 给的规则和手写的一样，要先看预览再决定保不保存。
      setState(() {
        _steps = <GalTextProcessStep>[..._steps, ...suggestion.steps];
        _aiMessage = t.game_text_process_ai_added(
          count: suggestion.steps.length,
        );
        _aiExplanation = suggestion.explanation;
      });
    } on AiChatFailure catch (failure) {
      if (!mounted) return;
      setState(
        () => _aiMessage = t.game_text_process_ai_failed(
          reason: _aiErrorText(failure.message),
        ),
      );
    } finally {
      client.close();
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  /// 把 [AiChatFailure.message] 的脱敏短码翻成本地化文案。
  String _aiErrorText(String code) {
    switch (code) {
      case 'unauthorized':
        return t.ai_error_unauthorized;
      case 'rate_limited':
        return t.ai_error_rate_limited;
      case 'network_error':
        return t.ai_error_network;
      case 'bad_response':
        return t.ai_error_bad_response;
      case 'empty_response':
        return t.ai_error_empty_response;
      case 'provider_not_configured':
        return t.ai_error_not_configured;
    }
    if (code.startsWith('http_')) {
      return t.ai_error_http(code: code.substring(5));
    }
    return code;
  }

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (bool didPop, _) {
        if (!didPop) unawaited(_attemptClose());
      },
      child: FushiToolScaffold(
        title: t.game_text_process_title,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.card,
                tokens.spacing.gap,
                tokens.spacing.card,
                0,
              ),
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final Widget preview = _buildPreview(tokens);
                  final Widget controls = _buildControls(tokens);
                  if (constraints.maxWidth >= _kWideBreakpoint) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Expanded(flex: 5, child: preview),
                        SizedBox(width: tokens.spacing.card),
                        SizedBox(width: _kControlsWidth, child: controls),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      SizedBox(height: _kNarrowPreviewHeight, child: preview),
                      SizedBox(height: tokens.spacing.card),
                      Expanded(child: controls),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.card,
              vertical: tokens.spacing.gap,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  key: const ValueKey<String>('gtp-cancel'),
                  onPressed: _attemptClose,
                  child: Text(t.dialog_cancel),
                ),
                SizedBox(width: tokens.spacing.gap),
                FilledButton.icon(
                  key: const ValueKey<String>('gtp-save'),
                  onPressed: _isDirty ? _save : null,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(t.dialog_save),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 左侧：活预览 ─────────────────────────────────────────────────────────

  Widget _buildPreview(FushiDesignTokens tokens) {
    final GalTextProcessTrace trace = _draftPipeline.run(_sample);
    final bool hasLatest = (widget.latestSample?.call() ?? '').isNotEmpty;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.game_text_process_preview, style: tokens.type.sectionLabel),
          SizedBox(height: tokens.spacing.gap),
          FushiTextField(
            key: const ValueKey<String>('gtp-sample-field'),
            controller: _sampleController,
            labelText: t.game_text_process_preview_input,
            hintText: t.game_text_process_preview_input_hint,
            minLines: 1,
            maxLines: 3,
            // 预览是活的：每敲一个字就重跑整条管线（纯字符串处理，行级文本上无成本）。
            onChanged: (_) => setState(() {}),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey<String>('gtp-use-latest'),
              onPressed: hasLatest ? _useLatestSample : null,
              icon: const Icon(Icons.history, size: 18),
              label: Text(t.game_text_process_preview_use_latest),
            ),
          ),
          for (int i = 0; i < trace.steps.length; i += 1) ...<Widget>[
            _buildStepTraceCard(tokens, i, trace.steps[i]),
            SizedBox(height: tokens.spacing.gap),
          ],
          _buildResultCard(tokens, trace),
          SizedBox(height: tokens.spacing.card),
        ],
      ),
    );
  }

  /// 一步的留痕卡：名称 + 输入 → 输出，改动段高亮。
  ///
  /// 三种要一眼看出的状态：**跳过**（步骤 disabled，整卡淡显）、**没改动**（淡显文案）、
  /// **把整行清空**（错误色卡底 + 显式说明——空行会被 poll 路径整行丢弃）。
  Widget _buildStepTraceCard(
    FushiDesignTokens tokens,
    int index,
    GalTextProcessStepTrace trace,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool skipped = !trace.step.enabled;
    final _TextAffixes affixes = _commonAffixes(trace.input, trace.output);
    final Widget card = FushiCard(
      key: ValueKey<String>('gtp-trace-${trace.step.id}'),
      color: trace.emptied ? scheme.errorContainer : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                skipped ? Icons.toggle_off_outlined : Icons.south,
                size: 16,
                color: tokens.surfaces.onVariant,
              ),
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: Text(
                  '${index + 1}. ${_kindLabel(trace.step.kind)}',
                  style: tokens.type.listTitle,
                ),
              ),
            ],
          ),
          SizedBox(height: tokens.spacing.gap),
          if (!trace.changed)
            Text(
              t.game_text_process_preview_step_unchanged,
              style: tokens.type.listSubtitle,
            )
          else ...<Widget>[
            _buildAffixText(
              text: trace.input,
              affixes: affixes,
              highlight: scheme.error,
              base: tokens.type.listSubtitle,
              strikeMiddle: true,
            ),
            SizedBox(height: tokens.spacing.gap / 2),
            _buildAffixText(
              text: trace.output,
              affixes: affixes,
              highlight: scheme.primary,
              base: tokens.type.listTitle,
            ),
          ],
          if (trace.emptied) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            _buildEmptiedNotice(tokens, scheme.onErrorContainer),
          ],
        ],
      ),
    );
    // disabled 的步骤仍然占一张卡（顺序是用户排出来的，抽掉会让编号对不上），
    // 但整卡淡显——「这一步这次没跑」必须看得出来。
    return skipped ? Opacity(opacity: 0.45, child: card) : card;
  }

  Widget _buildResultCard(FushiDesignTokens tokens, GalTextProcessTrace trace) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return FushiCard(
      key: const ValueKey<String>('gtp-result'),
      color: trace.emptied ? scheme.errorContainer : tokens.surfaces.group,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t.game_text_process_preview_result,
            style: tokens.type.sectionLabel,
          ),
          SizedBox(height: tokens.spacing.gap),
          Text(
            trace.output.isEmpty ? _kEmptyGlyph : trace.output,
            key: const ValueKey<String>('gtp-result-text'),
            style: tokens.type.listTitle,
          ),
          if (!trace.changed) ...<Widget>[
            SizedBox(height: tokens.spacing.gap / 2),
            Text(
              t.game_text_process_preview_unchanged,
              style: tokens.type.listSubtitle,
            ),
          ],
          if (trace.emptied) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            _buildEmptiedNotice(tokens, scheme.onErrorContainer),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptiedNotice(FushiDesignTokens tokens, Color color) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Icon(Icons.report_problem_outlined, size: 16, color: color),
      SizedBox(width: tokens.spacing.gap),
      Expanded(
        child: Text(
          t.game_text_process_preview_emptied,
          style: tokens.type.listSubtitle.copyWith(color: color),
        ),
      ),
    ],
  );

  /// 按公共前后缀把中间那段标出来。
  Widget _buildAffixText({
    required String text,
    required _TextAffixes affixes,
    required Color highlight,
    required TextStyle base,
    bool strikeMiddle = false,
  }) {
    if (text.isEmpty) {
      return Text(_kEmptyGlyph, style: base);
    }
    final int end = text.length - affixes.suffix;
    if (end <= affixes.prefix) {
      // 这一侧没有「独有」的中间段（纯插入或纯删除的另一侧），整串按基线样式显示。
      return Text(text, style: base);
    }
    return Text.rich(
      TextSpan(
        style: base,
        children: <InlineSpan>[
          if (affixes.prefix > 0)
            TextSpan(text: text.substring(0, affixes.prefix)),
          TextSpan(
            text: text.substring(affixes.prefix, end),
            style: TextStyle(
              color: highlight,
              decoration: strikeMiddle ? TextDecoration.lineThrough : null,
              decorationColor: highlight,
            ),
          ),
          if (affixes.suffix > 0) TextSpan(text: text.substring(end)),
        ],
      ),
    );
  }

  // ── 右侧：步骤列表 + AI ──────────────────────────────────────────────────

  Widget _buildControls(FushiDesignTokens tokens) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.game_text_process_summary, style: tokens.type.listSubtitle),
          SizedBox(height: tokens.spacing.gap),
          if (_steps.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: tokens.spacing.card),
              child: Text(
                t.game_text_process_empty,
                key: const ValueKey<String>('gtp-empty'),
                textAlign: TextAlign.center,
                style: tokens.type.listSubtitle,
              ),
            )
          else
            FushiReorderableColumn(
              itemCount: _steps.length,
              spacing: tokens.spacing.gap,
              feedbackBorderRadius: tokens.radii.cardRadius,
              keyForIndex: (int index) =>
                  ValueKey<String>('gtp-step-row-${_steps[index].id}'),
              onReorder: _reorder,
              itemBuilder: (BuildContext context, int index) =>
                  _buildStepCard(tokens, _steps[index]),
            ),
          SizedBox(height: tokens.spacing.gap),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.tonalIcon(
              key: const ValueKey<String>('gtp-add-step'),
              onPressed: _promptAddStep,
              icon: const Icon(Icons.add),
              label: Text(t.game_text_process_add_step),
            ),
          ),
          if (_hasAutoDedupe) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            _buildWarning(
              tokens,
              const ValueKey<String>('gtp-fold-warning'),
              t.game_text_process_fold_warning,
            ),
          ],
          if (_hasRubyRisk) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            _buildWarning(
              tokens,
              const ValueKey<String>('gtp-ruby-warning'),
              t.game_text_process_ruby_warning,
            ),
          ],
          SizedBox(height: tokens.spacing.section),
          _buildAiSection(tokens),
          SizedBox(height: tokens.spacing.card),
        ],
      ),
    );
  }

  Widget _buildWarning(FushiDesignTokens tokens, Key key, String message) =>
      FushiCard(
        key: key,
        color: tokens.surfaces.selected,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              Icons.info_outline,
              size: 18,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
            SizedBox(width: tokens.spacing.gap),
            Expanded(
              child: Text(
                message,
                style: tokens.type.listSubtitle.copyWith(
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _buildStepCard(FushiDesignTokens tokens, GalTextProcessStep step) {
    return FushiCard(
      key: ValueKey<String>('gtp-step-${step.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.drag_handle,
                size: 18,
                color: tokens.surfaces.onVariant,
              ),
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(_kindLabel(step.kind), style: tokens.type.listTitle),
                    Text(
                      _kindDescription(step.kind),
                      style: tokens.type.listSubtitle,
                    ),
                  ],
                ),
              ),
              Switch(
                key: ValueKey<String>('gtp-step-enabled-${step.id}'),
                value: step.enabled,
                onChanged: (bool value) => _updateStep(
                  step.id,
                  (GalTextProcessStep s) => s.copyWith(enabled: value),
                ),
              ),
              IconButton(
                key: ValueKey<String>('gtp-step-delete-${step.id}'),
                tooltip: t.dialog_delete,
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () => _removeStep(step.id),
              ),
            ],
          ),
          ..._buildStepParameters(tokens, step),
        ],
      ),
    );
  }

  List<Widget> _buildStepParameters(
    FushiDesignTokens tokens,
    GalTextProcessStep step,
  ) {
    if (!step.kind.hasParameters) {
      return const <Widget>[];
    }
    return <Widget>[
      SizedBox(height: tokens.spacing.gap),
      ...switch (step.kind) {
        GalTextProcessKind.takeLines => _buildTakeLinesParameters(tokens, step),
        GalTextProcessKind.dedupeChars || GalTextProcessKind.dedupeBlockFixed =>
          _buildRepeatParameters(tokens, step),
        GalTextProcessKind.filterLineBreaks => <Widget>[
          FushiTextField(
            key: ValueKey<String>('gtp-step-line-replacement-${step.id}'),
            initialValue: step.replacement,
            labelText: t.game_text_process_param_line_replacement,
            onChanged: (String value) => _updateStep(
              step.id,
              (GalTextProcessStep s) => s.copyWith(replacement: value),
            ),
          ),
        ],
        GalTextProcessKind.replace => _buildReplaceParameters(tokens, step),
        _ => const <Widget>[],
      },
    ];
  }

  List<Widget> _buildTakeLinesParameters(
    FushiDesignTokens tokens,
    GalTextProcessStep step,
  ) => <Widget>[
    FushiTextField(
      key: ValueKey<String>('gtp-step-line-count-${step.id}'),
      initialValue: '${step.lineCount}',
      labelText: t.game_text_process_param_lines,
      keyboardType: TextInputType.number,
      onChanged: (String value) {
        final int? parsed = int.tryParse(value.trim());
        // 解析不出来（空串、半个数字）保留原值：边打字边把行数清成 0 会让预览
        // 在每一次击键之间闪一遍「整条管线失效」。
        if (parsed == null || parsed <= 0) return;
        _updateStep(
          step.id,
          (GalTextProcessStep s) => s.copyWith(lineCount: parsed),
        );
      },
    ),
    SizedBox(height: tokens.spacing.gap),
    _buildSwitchRow(
      tokens,
      key: ValueKey<String>('gtp-step-from-end-${step.id}'),
      label: t.game_text_process_param_from_end,
      value: step.fromEnd,
      onChanged: (bool value) => _updateStep(
        step.id,
        (GalTextProcessStep s) => s.copyWith(fromEnd: value),
      ),
    ),
  ];

  List<Widget> _buildRepeatParameters(
    FushiDesignTokens tokens,
    GalTextProcessStep step,
  ) => <Widget>[
    _buildSwitchRow(
      tokens,
      key: ValueKey<String>('gtp-step-repeat-auto-${step.id}'),
      label: t.game_text_process_param_repeat_auto,
      value: step.repeatCount == null,
      onChanged: (bool value) => _updateStep(
        step.id,
        (GalTextProcessStep s) => value
            ? s.copyWith(clearRepeatCount: true)
            : s.copyWith(repeatCount: 2),
      ),
    ),
    if (step.repeatCount != null) ...<Widget>[
      SizedBox(height: tokens.spacing.gap),
      FushiTextField(
        key: ValueKey<String>('gtp-step-repeat-${step.id}'),
        initialValue: '${step.repeatCount}',
        labelText: t.game_text_process_param_repeat,
        keyboardType: TextInputType.number,
        onChanged: (String value) {
          final int? parsed = int.tryParse(value.trim());
          if (parsed == null || parsed <= 1) return;
          _updateStep(
            step.id,
            (GalTextProcessStep s) => s.copyWith(repeatCount: parsed),
          );
        },
      ),
    ],
  ];

  List<Widget> _buildReplaceParameters(
    FushiDesignTokens tokens,
    GalTextProcessStep step,
  ) {
    // 空模式不是「写错了」，是「还没写」——刚加的一步不该一上来就标红。
    final bool invalidPattern =
        step.isRegex &&
        step.pattern.isNotEmpty &&
        tryCompileGalTextPattern(step.pattern) == null;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return <Widget>[
      FushiTextField(
        key: ValueKey<String>('gtp-step-pattern-${step.id}'),
        initialValue: step.pattern,
        labelText: t.game_text_process_param_pattern,
        style: invalidPattern
            ? tokens.type.listTitle.copyWith(color: scheme.error)
            : null,
        onChanged: (String value) => _updateStep(
          step.id,
          (GalTextProcessStep s) => s.copyWith(pattern: value),
        ),
      ),
      if (invalidPattern) ...<Widget>[
        SizedBox(height: tokens.spacing.gap / 2),
        Text(
          t.game_text_process_param_pattern_invalid,
          key: ValueKey<String>('gtp-step-pattern-invalid-${step.id}'),
          style: tokens.type.listSubtitle.copyWith(color: scheme.error),
        ),
      ],
      SizedBox(height: tokens.spacing.gap),
      FushiTextField(
        key: ValueKey<String>('gtp-step-replacement-${step.id}'),
        initialValue: step.replacement,
        labelText: t.game_text_process_param_replacement,
        onChanged: (String value) => _updateStep(
          step.id,
          (GalTextProcessStep s) => s.copyWith(replacement: value),
        ),
      ),
      SizedBox(height: tokens.spacing.gap),
      _buildSwitchRow(
        tokens,
        key: ValueKey<String>('gtp-step-regex-${step.id}'),
        label: t.game_text_process_param_regex,
        value: step.isRegex,
        onChanged: (bool value) => _updateStep(
          step.id,
          (GalTextProcessStep s) => s.copyWith(isRegex: value),
        ),
      ),
    ];
  }

  Widget _buildSwitchRow(
    FushiDesignTokens tokens, {
    required Key key,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => Row(
    children: <Widget>[
      Expanded(child: Text(label, style: tokens.type.listSubtitle)),
      Switch(key: key, value: value, onChanged: onChanged),
    ],
  );

  Future<void> _promptAddStep() async {
    final Set<GalTextProcessKind> used = _steps
        .map((GalTextProcessStep step) => step.kind)
        .toSet();
    final GalTextProcessKind? picked = await showAppDialog<GalTextProcessKind>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(t.game_text_process_add_step),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // 已在管线里且不允许重复的种类整条隐藏（只有「替换」允许多条）：
                // 列出来再置灰只会让 17 行的列表更难扫。
                for (final GalTextProcessKind kind in GalTextProcessKind.values)
                  if (kind.allowsDuplicates || !used.contains(kind))
                    FushiListItem(
                      key: ValueKey<String>('gtp-add-${kind.storageKey}'),
                      title: Text(_kindLabel(kind)),
                      subtitle: Text(_kindDescription(kind)),
                      titleMaxLines: 2,
                      subtitleMaxLines: 3,
                      onTap: () => Navigator.of(dialogContext).pop(kind),
                    ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(t.dialog_cancel),
          ),
        ],
      ),
    );
    if (picked != null && mounted) _addStep(picked);
  }

  Widget _buildAiSection(FushiDesignTokens tokens) {
    return FushiCard(
      key: const ValueKey<String>('gtp-ai-section'),
      color: tokens.surfaces.group,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(t.game_text_process_ai_section, style: tokens.type.sectionLabel),
          SizedBox(height: tokens.spacing.gap),
          FushiTextField(
            key: const ValueKey<String>('gtp-ai-request'),
            controller: _aiRequestController,
            hintText: t.game_text_process_ai_hint,
            minLines: 1,
            maxLines: 3,
          ),
          SizedBox(height: tokens.spacing.gap),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              key: const ValueKey<String>('gtp-ai-generate'),
              onPressed: _aiBusy ? null : () => unawaited(_runAi()),
              icon: _aiBusy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_outlined),
              label: Text(t.game_text_process_ai_generate),
            ),
          ),
          if (_aiMessage != null) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            Text(
              _aiMessage!,
              key: const ValueKey<String>('gtp-ai-message'),
              style: tokens.type.listSubtitle,
            ),
          ],
          if (_aiExplanation.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.gap / 2),
            Text(
              _aiExplanation,
              key: const ValueKey<String>('gtp-ai-explanation'),
              style: tokens.type.listSubtitle,
            ),
          ],
        ],
      ),
    );
  }

  String _kindLabel(GalTextProcessKind kind) => switch (kind) {
    GalTextProcessKind.filterNonJapanese =>
      t.game_text_process_kind_filter_non_japanese,
    GalTextProcessKind.filterControlChars =>
      t.game_text_process_kind_filter_control_chars,
    GalTextProcessKind.filterAsciiPunctuation =>
      t.game_text_process_kind_filter_ascii_punctuation,
    GalTextProcessKind.keepJapaneseQuotes =>
      t.game_text_process_kind_keep_japanese_quotes,
    GalTextProcessKind.stripCurlyBraces =>
      t.game_text_process_kind_strip_curly_braces,
    GalTextProcessKind.normalizeWidth =>
      t.game_text_process_kind_normalize_width,
    GalTextProcessKind.takeLines => t.game_text_process_kind_take_lines,
    GalTextProcessKind.dedupeChars => t.game_text_process_kind_dedupe_chars,
    GalTextProcessKind.dedupeBlockFixed =>
      t.game_text_process_kind_dedupe_block_fixed,
    GalTextProcessKind.dedupeLinesAuto =>
      t.game_text_process_kind_dedupe_lines_auto,
    GalTextProcessKind.dedupeDescending =>
      t.game_text_process_kind_dedupe_descending,
    GalTextProcessKind.dedupeAscending =>
      t.game_text_process_kind_dedupe_ascending,
    GalTextProcessKind.stripAngleBrackets =>
      t.game_text_process_kind_strip_angle_brackets,
    GalTextProcessKind.filterLineBreaks =>
      t.game_text_process_kind_filter_line_breaks,
    GalTextProcessKind.filterDigits => t.game_text_process_kind_filter_digits,
    GalTextProcessKind.filterLatinLetters =>
      t.game_text_process_kind_filter_latin_letters,
    GalTextProcessKind.replace => t.game_text_process_kind_replace,
  };

  String _kindDescription(GalTextProcessKind kind) => switch (kind) {
    GalTextProcessKind.filterNonJapanese =>
      t.game_text_process_kind_filter_non_japanese_desc,
    GalTextProcessKind.filterControlChars =>
      t.game_text_process_kind_filter_control_chars_desc,
    GalTextProcessKind.filterAsciiPunctuation =>
      t.game_text_process_kind_filter_ascii_punctuation_desc,
    GalTextProcessKind.keepJapaneseQuotes =>
      t.game_text_process_kind_keep_japanese_quotes_desc,
    GalTextProcessKind.stripCurlyBraces =>
      t.game_text_process_kind_strip_curly_braces_desc,
    GalTextProcessKind.normalizeWidth =>
      t.game_text_process_kind_normalize_width_desc,
    GalTextProcessKind.takeLines => t.game_text_process_kind_take_lines_desc,
    GalTextProcessKind.dedupeChars =>
      t.game_text_process_kind_dedupe_chars_desc,
    GalTextProcessKind.dedupeBlockFixed =>
      t.game_text_process_kind_dedupe_block_fixed_desc,
    GalTextProcessKind.dedupeLinesAuto =>
      t.game_text_process_kind_dedupe_lines_auto_desc,
    GalTextProcessKind.dedupeDescending =>
      t.game_text_process_kind_dedupe_descending_desc,
    GalTextProcessKind.dedupeAscending =>
      t.game_text_process_kind_dedupe_ascending_desc,
    GalTextProcessKind.stripAngleBrackets =>
      t.game_text_process_kind_strip_angle_brackets_desc,
    GalTextProcessKind.filterLineBreaks =>
      t.game_text_process_kind_filter_line_breaks_desc,
    GalTextProcessKind.filterDigits =>
      t.game_text_process_kind_filter_digits_desc,
    GalTextProcessKind.filterLatinLetters =>
      t.game_text_process_kind_filter_latin_letters_desc,
    GalTextProcessKind.replace => t.game_text_process_kind_replace_desc,
  };
}

/// 一对公共前后缀长度（以 UTF-16 码元计）。
class _TextAffixes {
  const _TextAffixes(this.prefix, this.suffix);

  final int prefix;
  final int suffix;
}

/// 算两串的公共前缀与公共后缀长度，中间那段视为「这一步改动的部分」。
///
/// 刻意**不做逐字 diff**：预览要在每次击键后重跑，而这里只需要「改了哪一块」这个量级的
/// 信息。单点编辑（正则替换、删尾部标签）能精确圈出改动段；整串过滤（去半角标点）会退化
/// 成整行高亮——退化方向是「全标出来」而不是「标错地方」，仍然可读。
///
/// 前后缀边界都不允许落在代理对中间，否则 `substring` 会切出半个字符、渲染成替换符。
_TextAffixes _commonAffixes(String a, String b) {
  final int limit = a.length < b.length ? a.length : b.length;
  int prefix = 0;
  while (prefix < limit && a.codeUnitAt(prefix) == b.codeUnitAt(prefix)) {
    prefix += 1;
  }
  if (prefix > 0 && prefix < limit) {
    final int last = a.codeUnitAt(prefix - 1);
    if (last >= 0xD800 && last <= 0xDBFF) {
      prefix -= 1; // 别把高代理和它的低代理切开。
    }
  }
  int suffix = 0;
  while (suffix < limit - prefix &&
      a.codeUnitAt(a.length - suffix - 1) ==
          b.codeUnitAt(b.length - suffix - 1)) {
    suffix += 1;
  }
  while (suffix > 0) {
    final int first = a.codeUnitAt(a.length - suffix);
    if (first >= 0xDC00 && first <= 0xDFFF) {
      suffix -= 1; // 后缀不能以一个孤立低代理开头。
      continue;
    }
    break;
  }
  return _TextAffixes(prefix, suffix);
}
