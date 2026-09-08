/// Anki 卡组新卡按词频重排的 UI：配置弹窗（卡组 / 词频来源 / 词典多选 /
/// 复合方式 / 方向）→ 带进度的计划 → 预览 → 执行 → 结果；外加撤销上次重排。
///
/// 所有写回都先经过预览确认；预览里能看到每张卡的 rank，换词典后顺序怎么变
/// 用户执行前就看得见。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/src/anki/anki_deck_reposition.dart';
import 'package:fushi/src/anki/anki_deck_reposition_runner.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/utils.dart';

/// 打开重排配置弹窗。[loadedFrequencyDictionaries] = 引擎当前装载的词频词典名
/// （隐藏的不在里面）。
Future<void> showAnkiDeckRepositionDialog(
  BuildContext context, {
  required AnkiViewModel viewModel,
  required List<String> loadedFrequencyDictionaries,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => _RepositionDialog(
      viewModel: viewModel,
      loadedDictionaries: loadedFrequencyDictionaries,
    ),
  );
}

class _RepositionDialog extends StatefulWidget {
  const _RepositionDialog({
    required this.viewModel,
    required this.loadedDictionaries,
  });

  final AnkiViewModel viewModel;
  final List<String> loadedDictionaries;

  @override
  State<_RepositionDialog> createState() => _RepositionDialogState();
}

class _RepositionDialogState extends State<_RepositionDialog> {
  late AnkiSettings _settings;
  late int? _deckId;
  late AnkiRepositionSource _source;
  late Set<String> _dictionaries;
  late FrequencyAggregate _aggregate;
  bool _rareFirst = false;
  bool _busy = false;
  AnkiRepositionSnapshot? _snapshot;

  AnkiDeckRepositionRunner get _runner => widget.viewModel.deckRepositionRunner;

  @override
  void initState() {
    super.initState();
    _settings = widget.viewModel.settings;
    final List<AnkiDeck> decks = _settings.availableDecks;
    _deckId = decks.any((AnkiDeck d) => d.id == _settings.selectedDeckId)
        ? _settings.selectedDeckId
        : (decks.isEmpty ? null : decks.first.id);
    _source = _settings.repositionSource;
    // 只保留还装着的词典；一本都不剩就回到「全部」。
    _dictionaries = _settings.repositionDictionaries
        .where(widget.loadedDictionaries.contains)
        .toSet();
    _aggregate = FrequencyAggregate.fromName(_settings.repositionAggregate);
    unawaited(_refreshSnapshot());
  }

  String? get _deckName => _settings.availableDecks
      .where((AnkiDeck d) => d.id == _deckId)
      .map((AnkiDeck d) => d.name)
      .firstOrNull;

  Future<void> _refreshSnapshot() async {
    final String? deck = _deckName;
    if (deck == null) return;
    AnkiRepositionSnapshot? s;
    try {
      s = await _runner.latestSnapshot(deck);
    } catch (_) {
      s = null;
    }
    if (mounted) setState(() => _snapshot = s);
  }

  AnkiRepositionRankOptions get _options => AnkiRepositionRankOptions(
        source: _source,
        dictionaries: _dictionaries,
        aggregate: _aggregate,
        rareFirst: _rareFirst,
      );

  Future<void> _persistOptions() => widget.viewModel.setRepositionOptions(
        source: _source,
        dictionaries: _dictionaries.toList()..sort(),
        aggregate: _aggregate.name,
      );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? hintStyle = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final List<AnkiDeck> decks = _settings.availableDecks;
    final bool dictsMode = _source == AnkiRepositionSource.dictionaries;
    final bool canRun = !_busy &&
        _deckName != null &&
        (!dictsMode || widget.loadedDictionaries.isNotEmpty);

    return AlertDialog(
      title: Text(t.anki_reposition_title),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(t.anki_reposition_hint, style: hintStyle),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                key: const Key('anki_reposition_deck'),
                value: _deckId,
                decoration: InputDecoration(
                  labelText: t.anki_deck,
                  helperText: t.anki_reposition_include_subdecks_hint,
                  helperMaxLines: 2,
                ),
                items: <DropdownMenuItem<int>>[
                  for (final AnkiDeck d in decks)
                    DropdownMenuItem<int>(
                      value: d.id,
                      child: Text(d.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (int? id) {
                        setState(() => _deckId = id);
                        unawaited(_refreshSnapshot());
                      },
              ),
              const SizedBox(height: 16),
              Text(t.anki_reposition_source, style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              SegmentedButton<AnkiRepositionSource>(
                key: const Key('anki_reposition_source'),
                segments: <ButtonSegment<AnkiRepositionSource>>[
                  ButtonSegment<AnkiRepositionSource>(
                    value: AnkiRepositionSource.dictionaries,
                    label: Text(t.anki_reposition_source_dictionaries),
                    icon: const Icon(Icons.menu_book_outlined),
                  ),
                  ButtonSegment<AnkiRepositionSource>(
                    value: AnkiRepositionSource.field,
                    label: Text(t.anki_reposition_source_field),
                    icon: const Icon(Icons.text_fields),
                  ),
                ],
                selected: <AnkiRepositionSource>{_source},
                onSelectionChanged: _busy
                    ? null
                    : (Set<AnkiRepositionSource> s) =>
                        setState(() => _source = s.first),
              ),
              const SizedBox(height: 8),
              if (dictsMode) ..._buildDictionaryControls(theme, hintStyle),
              if (!dictsMode)
                Text(t.anki_reposition_source_field_hint, style: hintStyle),
              AdaptiveSettingsSwitchRow(
                key: const Key('anki_reposition_rare_first'),
                title: t.anki_reposition_rare_first,
                value: _rareFirst,
                horizontalPadding: 0,
                onChanged:
                    _busy ? null : (bool v) => setState(() => _rareFirst = v),
              ),
              Text(t.anki_reposition_gather_order_hint, style: hintStyle),
              if (_snapshot != null) ...<Widget>[
                const Divider(height: 24),
                AdaptiveSettingsRow(
                  key: const Key('anki_reposition_undo'),
                  icon: Icons.undo,
                  showIcon: true,
                  horizontalPadding: 0,
                  title: t.anki_reposition_undo,
                  subtitle: t.anki_reposition_undo_hint(
                    time: _snapshot!.createdAt
                        .toLocal()
                        .toString()
                        .split('.')
                        .first,
                  ),
                  subtitleMaxLines: 3,
                  onTap: _busy ? null : _undo,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(t.dialog_cancel),
        ),
        FilledButton(
          key: const Key('anki_reposition_preview'),
          onPressed: canRun ? _previewAndApply : null,
          child: Text(t.anki_reposition_preview),
        ),
      ],
    );
  }

  List<Widget> _buildDictionaryControls(
    ThemeData theme,
    TextStyle? hintStyle,
  ) {
    final List<String> loaded = widget.loadedDictionaries;
    if (loaded.isEmpty) {
      return <Widget>[
        Text(
          t.anki_reposition_dicts_none,
          style: hintStyle?.copyWith(color: theme.colorScheme.error),
        ),
        Text(t.anki_reposition_dicts_hint, style: hintStyle),
      ];
    }
    return <Widget>[
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: <Widget>[
          for (final String name in loaded)
            FilterChip(
              key: Key('anki_reposition_dict_$name'),
              label: Text(name),
              selected: _dictionaries.contains(name),
              onSelected: _busy
                  ? null
                  : (bool on) => setState(() {
                        if (on) {
                          _dictionaries.add(name);
                        } else {
                          _dictionaries.remove(name);
                        }
                      }),
            ),
        ],
      ),
      const SizedBox(height: 4),
      Text(t.anki_reposition_dicts_hint, style: hintStyle),
      if (loaded.length > 1 &&
          (_dictionaries.isEmpty || _dictionaries.length > 1)) ...<Widget>[
        const SizedBox(height: 8),
        DropdownButtonFormField<FrequencyAggregate>(
          key: const Key('anki_reposition_aggregate'),
          value: _aggregate,
          decoration: InputDecoration(labelText: t.anki_reposition_aggregate),
          items: <DropdownMenuItem<FrequencyAggregate>>[
            DropdownMenuItem<FrequencyAggregate>(
              value: FrequencyAggregate.harmonic,
              child: Text(t.anki_reposition_aggregate_harmonic),
            ),
            DropdownMenuItem<FrequencyAggregate>(
              value: FrequencyAggregate.min,
              child: Text(t.anki_reposition_aggregate_min),
            ),
          ],
          onChanged: _busy
              ? null
              : (FrequencyAggregate? v) {
                  if (v != null) setState(() => _aggregate = v);
                },
        ),
      ],
    ];
  }

  Future<void> _previewAndApply() async {
    final String? deck = _deckName;
    if (deck == null) return;
    await _persistOptions();
    if (!mounted) return;
    setState(() => _busy = true);
    final ScaffoldMessengerState? messenger =
        ScaffoldMessenger.maybeOf(context);
    try {
      final AnkiRepositionPlan? plan =
          await runAnkiRepositionWithProgress<AnkiRepositionPlan?>(
        context,
        (AnkiRepositionOnProgress onProgress, bool Function() shouldCancel) =>
            _runner.plan(
          deckName: deck,
          settings: _settings,
          options: _options,
          onProgress: onProgress,
          shouldCancel: shouldCancel,
        ),
      );
      if (!mounted) return;
      if (plan == null) {
        messenger?.showSnackBar(
          SnackBar(content: Text(t.anki_reposition_cancelled)),
        );
        return;
      }
      if (plan.total == 0) {
        messenger?.showSnackBar(
          SnackBar(content: Text(t.anki_reposition_empty)),
        );
        return;
      }
      final bool confirmed = await showAnkiRepositionPreviewDialog(
        context,
        plan,
      );
      if (!confirmed || !mounted) return;
      final AnkiRepositionOutcome? outcome =
          await runAnkiRepositionWithProgress<AnkiRepositionOutcome>(
        context,
        (AnkiRepositionOnProgress onProgress, bool Function() _) =>
            _runner.apply(plan, onProgress: onProgress),
        cancellable: false,
      );
      if (!mounted || outcome == null) return;
      messenger?.showSnackBar(SnackBar(
        content: Text(outcome.failures.isEmpty
            ? t.anki_reposition_done(count: outcome.written)
            : t.anki_reposition_partial(
                failed: outcome.failures.length,
                error: outcome.failures.values.first,
              )),
      ));
      await _refreshSnapshot();
    } on AnkiRepositionCancelled {
      messenger?.showSnackBar(
        SnackBar(content: Text(t.anki_reposition_cancelled)),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text(t.anki_reposition_failed(error: '$e'))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _undo() async {
    final AnkiRepositionSnapshot? snapshot = _snapshot;
    if (snapshot == null) return;
    setState(() => _busy = true);
    final ScaffoldMessengerState? messenger =
        ScaffoldMessenger.maybeOf(context);
    try {
      final AnkiRepositionUndoOutcome? outcome =
          await runAnkiRepositionWithProgress<AnkiRepositionUndoOutcome>(
        context,
        (AnkiRepositionOnProgress onProgress, bool Function() _) {
          onProgress(
            const AnkiRepositionProgress(stage: AnkiRepositionStage.write),
          );
          return _runner.undo(snapshot);
        },
        cancellable: false,
      );
      if (!mounted || outcome == null) return;
      messenger?.showSnackBar(SnackBar(
        content: Text(outcome.failures.isEmpty
            ? t.anki_reposition_undo_done(
                count: outcome.restored,
                skipped: outcome.skipped,
              )
            : t.anki_reposition_partial(
                failed: outcome.failures.length,
                error: outcome.failures.values.first,
              )),
      ));
      await _refreshSnapshot();
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text(t.anki_reposition_failed(error: '$e'))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// 带模态进度对话框跑一段重排任务；用户取消时返回 null（任务方通过
/// `shouldCancel` 看到取消并抛 [AnkiRepositionCancelled]，这里吞成 null）。
/// 其它异常原样上抛，上抛前保证进度弹窗已关。
Future<T?> runAnkiRepositionWithProgress<T>(
  BuildContext context,
  Future<T> Function(
    AnkiRepositionOnProgress onProgress,
    bool Function() shouldCancel,
  ) task, {
  bool cancellable = true,
}) async {
  final ValueNotifier<AnkiRepositionProgress?> progress =
      ValueNotifier<AnkiRepositionProgress?>(null);
  final ValueNotifier<bool> cancelRequested = ValueNotifier<bool>(false);
  BuildContext? dialogContext;
  bool dialogClosed = false;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) {
      dialogContext = ctx;
      return PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(t.anki_reposition_progress_title),
          content: SizedBox(
            width: 360,
            child: _RepositionProgressBody(progress: progress),
          ),
          actions: <Widget>[
            if (cancellable)
              ValueListenableBuilder<bool>(
                valueListenable: cancelRequested,
                builder: (BuildContext _, bool requested, Widget? __) =>
                    TextButton(
                  onPressed:
                      requested ? null : () => cancelRequested.value = true,
                  child: Text(t.dialog_cancel),
                ),
              ),
          ],
        ),
      );
    },
  ).then((void _) => dialogClosed = true));
  try {
    return await task(
      (AnkiRepositionProgress p) => progress.value = p,
      () => cancelRequested.value,
    );
  } on AnkiRepositionCancelled {
    return null;
  } finally {
    // 弹窗路由同步入栈但 builder 下一帧才跑：任务瞬间结束时 dialogContext 可能
    // 还是 null，等一帧再关，绝不留下关不掉的遮罩。
    if (dialogContext == null && !dialogClosed) {
      await Future<void>.delayed(Duration.zero);
    }
    final BuildContext? ctx = dialogContext;
    if (!dialogClosed && ctx != null && ctx.mounted) {
      Navigator.of(ctx).pop();
    }
    progress.dispose();
    cancelRequested.dispose();
  }
}

class _RepositionProgressBody extends StatelessWidget {
  const _RepositionProgressBody({required this.progress});

  final ValueNotifier<AnkiRepositionProgress?> progress;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AnkiRepositionProgress?>(
      valueListenable: progress,
      builder: (BuildContext context, AnkiRepositionProgress? p, Widget? _) {
        final bool determinate =
            p != null && p.stage == AnkiRepositionStage.rank && p.total > 0;
        final String label = switch (p?.stage) {
          null || AnkiRepositionStage.fetch => t.anki_reposition_progress_fetch,
          AnkiRepositionStage.rank => t.anki_reposition_progress_rank(
              done: p!.done,
              total: p.total,
            ),
          AnkiRepositionStage.write => t.anki_reposition_progress_write,
        };
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            LinearProgressIndicator(
              value: determinate ? p.done / p.total : null,
            ),
            const SizedBox(height: 12),
            Text(label),
          ],
        );
      },
    );
  }
}

/// 预览：汇总 + 前若干条（位置 / 表达式 / rank）。返回 true = 用户点了执行。
Future<bool> showAnkiRepositionPreviewDialog(
  BuildContext context,
  AnkiRepositionPlan plan, {
  int maxRows = 40,
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) {
      final ThemeData theme = Theme.of(ctx);
      final TextStyle? mono = theme.textTheme.bodySmall?.copyWith(
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        color: theme.colorScheme.onSurfaceVariant,
      );
      final List<AnkiRepositionCard> rows = plan.ordered.take(maxRows).toList();
      return AlertDialog(
        title: Text(t.anki_reposition_preview),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(t.anki_reposition_summary(
                total: plan.total,
                ranked: plan.ranked,
                unranked: plan.unranked,
                changed: plan.changed,
              )),
              if (plan.changed == 0) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  t.anki_reposition_unchanged,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  itemBuilder: (BuildContext _, int i) {
                    final AnkiRepositionCard c = rows[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: <Widget>[
                          SizedBox(
                            width: 40,
                            child: Text('${plan.updates[i].due}', style: mono),
                          ),
                          Expanded(
                            child: Text(
                              c.expression.isEmpty
                                  ? '#${c.card.noteId}'
                                  : c.expression,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            c.rank?.toString() ??
                                t.anki_reposition_no_frequency,
                            style: mono,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.dialog_cancel),
          ),
          FilledButton(
            key: const Key('anki_reposition_apply'),
            onPressed:
                plan.changed == 0 ? null : () => Navigator.of(ctx).pop(true),
            child: Text(t.anki_reposition_apply),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}
