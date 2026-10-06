import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/favorites/favorite_batch_mining_plan.dart';
import 'package:fushi/src/media/favorites/favorite_batch_mining_runner.dart';
import 'package:fushi/src/media/favorites/favorite_mining_item.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 收藏夹「一键制卡」入口是否该出现：制卡模块（[ModuleId.cardCreation]）被用户关掉时
/// 整个入口不渲染——与阅读器 / 视频页弹窗的制卡按钮同一个总闸。
bool favoriteBatchMiningAvailable(AppModel appModel) =>
    appModel.moduleVisibility.isEnabled(ModuleId.cardCreation);

/// 把 [items] 逐条写进 Anki：打开一个进度页，按顺序为每条查词、在可见的查词弹窗里
/// 渲染结果、取回与手动点「+」逐字段相同的制卡字段、配上句子媒体落卡，每条给出结果，
/// 全部结束后给一行汇总。页面关掉即返回（进行中关不掉，先停止）。
Future<void> showFavoriteBatchMining(
  BuildContext context,
  List<FavoriteMiningItem> items,
) async {
  if (items.isEmpty) return;
  await Navigator.push<void>(
    context,
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => FavoriteBatchMiningPage(items: items),
    ),
  );
}

/// 查词弹窗渲染完成的最长等待。冷启动 WebView（第一条、或低内存模式下）在 Windows 上
/// 要数秒；超过这个时长按「弹窗没加载出来」判这一条失败，继续下一条。
const Duration _kRenderTimeout = Duration(seconds: 30);

/// 进度页里嵌的查词弹窗高度（逻辑像素）。可见而非离屏：离屏 / 零尺寸的 WebView 在
/// Windows 上可能永远不触发渲染回执（WGC 帧池不给不可见表面出帧）。
const double _kPopupPreviewHeight = 260;

class FavoriteBatchMiningPage extends ConsumerStatefulWidget {
  const FavoriteBatchMiningPage({required this.items, super.key});

  final List<FavoriteMiningItem> items;

  @override
  ConsumerState<FavoriteBatchMiningPage> createState() =>
      _FavoriteBatchMiningPageState();
}

class _FavoriteBatchMiningPageState
    extends ConsumerState<FavoriteBatchMiningPage> {
  final GlobalKey<DictionaryPopupWebViewState> _popupKey =
      GlobalKey<DictionaryPopupWebViewState>();

  late final List<FavoriteBatchItemResult> _results =
      List<FavoriteBatchItemResult>.filled(
        widget.items.length,
        const FavoriteBatchItemResult.pending(),
      );

  DictionarySearchResult? _popupResult;
  Completer<void>? _renderWaiter;
  bool _running = false;
  bool _stopRequested = false;
  bool _finished = false;
  int _done = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  @override
  void dispose() {
    _stopRequested = true;
    final Completer<void>? waiter = _renderWaiter;
    _renderWaiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.completeError(StateError('batch mining page disposed'));
    }
    super.dispose();
  }

  Future<void> _run() async {
    if (!mounted) return;
    setState(() => _running = true);
    final AppModel appModel = ref.read(appProvider);
    final FavoriteBatchMiningRunner runner = FavoriteBatchMiningRunner(
      appModel: appModel,
      repo: ref.read(ankiRepositoryProvider),
    );
    for (int i = 0; i < widget.items.length; i++) {
      if (!mounted) return;
      if (_stopRequested) break;
      _setResult(
        i,
        const FavoriteBatchItemResult(status: FavoriteBatchItemStatus.running),
      );
      final FavoriteMiningItem item = widget.items[i];
      final FavoriteBatchMineOutcome outcome = await _mineOne(
        appModel,
        runner,
        item,
      );
      if (!mounted) return;
      _setResult(i, outcome.result);
      setState(() => _done = i + 1);
      if (outcome.abortBatch) {
        // Anki 未配置：后面每条都会同样失败——只报这一次，剩下的记跳过。
        FushiToast.show(
          msg: t.card_export_not_configured,
          severity: ToastSeverity.error,
        );
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      for (int i = 0; i < _results.length; i++) {
        if (!_results[i].isFinished) {
          _results[i] = const FavoriteBatchItemResult(
            status: FavoriteBatchItemStatus.skipped,
          );
        }
      }
      _running = false;
      _finished = true;
      // 结束后卸掉 WebView：页面还开着看结果，没必要再占一个原生表面。
      _popupResult = null;
    });
  }

  Future<FavoriteBatchMineOutcome> _mineOne(
    AppModel appModel,
    FavoriteBatchMiningRunner runner,
    FavoriteMiningItem item,
  ) async {
    final DictionarySearchResult result;
    try {
      result = await appModel.searchDictionary(
        searchTerm: item.expression,
        searchWithWildcards: false,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('FavoriteBatchMining.search', e, stack);
      return FavoriteBatchMineOutcome(
        FavoriteBatchItemResult(
          status: FavoriteBatchItemStatus.failed,
          message: '$e',
        ),
      );
    }
    if (!mounted) return _stoppedOutcome();
    if (result.entries.isEmpty) {
      return FavoriteBatchMineOutcome(
        FavoriteBatchItemResult(
          status: FavoriteBatchItemStatus.failed,
          message: t.favorites_batch_mine_no_entry,
        ),
      );
    }
    final bool rendered = await _showInPopup(result);
    if (!mounted) return _stoppedOutcome();
    final DictionaryPopupWebViewState? popup = _popupKey.currentState;
    final Map<String, String>? payload = rendered && popup != null
        ? await popup.buildMinePayloadFor(
            expression: item.expression,
            reading: item.reading,
          )
        : null;
    if (!mounted) return _stoppedOutcome();
    if (payload == null) {
      return FavoriteBatchMineOutcome(
        FavoriteBatchItemResult(
          status: FavoriteBatchItemStatus.failed,
          message: rendered
              ? t.favorites_batch_mine_no_entry
              : t.favorites_batch_mine_render_failed,
        ),
      );
    }
    if (!favoritePayloadBelongsToResult(
      payload: payload,
      itemExpression: item.expression,
      resultWords: result.entries.map((DictionaryEntry e) => e.word),
    )) {
      ErrorLogService.instance.log(
        'FavoriteBatchMining.payload',
        'popup payload for "${payload['expression']}" does not belong to the '
            'lookup of "${item.expression}" (stale render signal); item skipped',
        StackTrace.current,
      );
      return FavoriteBatchMineOutcome(
        FavoriteBatchItemResult(
          status: FavoriteBatchItemStatus.failed,
          message: t.favorites_batch_mine_render_failed,
        ),
      );
    }
    return runner.mine(item, payload);
  }

  FavoriteBatchMineOutcome _stoppedOutcome() => const FavoriteBatchMineOutcome(
    FavoriteBatchItemResult(status: FavoriteBatchItemStatus.skipped),
  );

  /// 把 [result] 推进可见的查词弹窗并等它渲染完。返回 false = 超时 / 渲染失败。
  ///
  /// 为什么等待在「这一帧 build 完之后」才开始接收渲染回执：弹窗的
  /// `popupRendered` 带渲染 token，token 在 `didUpdateWidget → _pushResults` 里
  /// 自增，旧 token 的晚到回执会被弹窗自己丢掉。我们在 post-frame 才挂上等待者，此时
  /// 新 token 已生效——之前那一条的尾批回执既过不了弹窗的 token 门，也碰不到这次的
  /// 等待者；而这一次的回执要经一次原生往返，不可能早于本帧结束。
  Future<bool> _showInPopup(DictionarySearchResult result) async {
    final DictionarySearchResult? previous = _popupResult;
    if (identical(previous, result)) {
      // 查词缓存命中同一个实例（同词收藏了两次）：弹窗不会重推，内容本来就是它。
      return true;
    }
    final Completer<void> waiter = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!waiter.isCompleted) _renderWaiter = waiter;
    });
    setState(() => _popupResult = result);
    try {
      await waiter.future.timeout(_kRenderTimeout);
      return true;
    } on TimeoutException {
      ErrorLogService.instance.log(
        'FavoriteBatchMining.render',
        'dictionary popup did not report popupRendered within '
            '${_kRenderTimeout.inSeconds}s for "${result.searchTerm}"',
        StackTrace.current,
      );
      return false;
    } catch (_) {
      return false;
    } finally {
      if (identical(_renderWaiter, waiter)) _renderWaiter = null;
    }
  }

  void _onPopupRendered() {
    final Completer<void>? waiter = _renderWaiter;
    _renderWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  void _onPopupRenderError() {
    final Completer<void>? waiter = _renderWaiter;
    _renderWaiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.completeError(StateError('dictionary popup render error'));
    }
  }

  void _setResult(int index, FavoriteBatchItemResult result) {
    if (!mounted) return;
    setState(() => _results[index] = result);
  }

  void _requestStop() {
    if (!_running) return;
    setState(() => _stopRequested = true);
  }

  @override
  Widget build(BuildContext context) {
    final int total = widget.items.length;
    final DictionarySearchResult? popupResult = _popupResult;
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        // 进行中按返回 = 停止（当前这一条写完就停），停下后再返回才真正离开，
        // 避免半路拆掉 WebView 让正在取的那条卡没头没尾。
        if (!didPop) _requestStop();
      },
      child: Scaffold(
        appBar: FushiAppBar(
          title: Text(t.favorites_batch_mine_title),
          actions: <Widget>[
            if (_running)
              FushiTextButton(
                onPressed: _stopRequested ? null : _requestStop,
                child: Text(t.stop),
              ),
            if (_finished)
              FushiTextButton(
                onPressed: () => Navigator.maybePop(context),
                child: Text(t.dialog_done),
              ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FushiLinearProgressIndicator(value: total == 0 ? 1 : _done / total),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                _finished
                    ? _summaryText(FavoriteBatchSummary.of(_results))
                    : t.favorites_batch_mine_progress(
                        done: _done,
                        total: total,
                      ),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (popupResult != null)
              SizedBox(
                height: _kPopupPreviewHeight,
                // 只展示、不交互：批量流程自己取字段落卡，用户在这里点「+」会与批量
                // 抢同一张卡。
                child: IgnorePointer(
                  child: FushiAppUiScaleNeutralizer(
                    child: DictionaryPopupWebView(
                      key: _popupKey,
                      result: popupResult,
                      onRendered: _onPopupRendered,
                      onRenderError: _onPopupRenderError,
                    ),
                  ),
                ),
              ),
            const FushiDividerControl(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: total,
                itemBuilder: (BuildContext context, int index) =>
                    _FavoriteBatchItemTile(
                      item: widget.items[index],
                      result: _results[index],
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _summaryText(FavoriteBatchSummary summary) =>
      t.favorites_batch_mine_summary(
        added: summary.added,
        duplicate: summary.duplicate,
        failed: summary.failed,
        skipped: summary.skipped,
      );
}

class _FavoriteBatchItemTile extends StatelessWidget {
  const _FavoriteBatchItemTile({required this.item, required this.result});

  final FavoriteMiningItem item;
  final FavoriteBatchItemResult result;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String headword =
        item.reading.isEmpty || item.reading == item.expression
        ? item.expression
        : '${item.expression}【${item.reading}】';
    final List<String> lines = <String>[
      if (item.sentence.isNotEmpty) item.sentence,
      if (result.status == FavoriteBatchItemStatus.added &&
          result.textOnlyReason != null)
        t.favorites_batch_mine_text_only,
      if (result.status == FavoriteBatchItemStatus.skipped)
        t.favorites_batch_mine_skipped,
      if (result.message != null && result.message!.isNotEmpty) result.message!,
    ];
    return FushiListItem(
      leading: _statusIcon(scheme),
      title: Text(headword),
      subtitleMaxLines: 4,
      subtitle: lines.isEmpty
          ? null
          : Text(
              lines.join('\n'),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
    );
  }

  Widget _statusIcon(ColorScheme scheme) => switch (result.status) {
    FavoriteBatchItemStatus.pending => FushiIcon(
      Icons.radio_button_unchecked,
      color: scheme.outline,
    ),
    FavoriteBatchItemStatus.running => const SizedBox.square(
      dimension: 24,
      child: Padding(
        padding: EdgeInsets.all(2),
        child: FushiCircularProgressIndicator(strokeWidth: 2.5),
      ),
    ),
    FavoriteBatchItemStatus.added => FushiIcon(
      result.textOnlyReason == null
          ? Icons.check_circle
          : Icons.check_circle_outline,
      color: scheme.primary,
    ),
    FavoriteBatchItemStatus.duplicate => FushiIcon(
      Icons.library_add_check_outlined,
      color: scheme.tertiary,
    ),
    FavoriteBatchItemStatus.failed => FushiIcon(
      Icons.error_outline,
      color: scheme.error,
    ),
    FavoriteBatchItemStatus.skipped => FushiIcon(
      Icons.remove_circle_outline,
      color: scheme.outline,
    ),
  };
}
