import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/favorites/favorite_batch_mining_plan.dart';
import 'package:fushi/src/media/favorites/favorite_batch_mining_runner.dart';
import 'package:fushi/src/media/favorites/favorite_mining_item.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
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
    final double gutter = FushiDesignTokens.of(context).spacing.page;
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        // 进行中按返回 = 停止（当前这一条写完就停），停下后再返回才真正离开，
        // 避免半路拆掉 WebView 让正在取的那条卡没头没尾。
        if (!didPop) _requestStop();
      },
      child: FushiPageScaffold(
        title: t.favorites_batch_mine_title,
        actions: <Widget>[
          if (_running)
            FushiFilledButton.tonalIcon(
              onPressed: _stopRequested ? null : _requestStop,
              icon: const FushiIcon(FushiIcons.stop),
              label: Text(t.stop),
            ),
          if (_finished)
            FushiFilledButton.icon(
              onPressed: () => Navigator.maybePop(context),
              icon: const FushiIcon(FushiIcons.check),
              label: Text(t.dialog_done),
            ),
        ],
        // 进度主卡原本固定在正文顶部：页头浮在正文上之后会被胶囊盖住，所以随
        // 页头一起进 headerBottom（页头 → 进度卡纵向堆叠、一起收起）；页头已有
        // 左右内边距，不再叠 gutter。
        headerBottom: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _FavoriteBatchProgressCard(
            done: _done,
            total: total,
            finished: _finished,
            label: _finished
                ? _summaryText(FavoriteBatchSummary.of(_results))
                : t.favorites_batch_mine_progress(done: _done, total: total),
          ),
        ),
        // Builder：正文要在页头脚手架之内取 MediaQuery 顶部让位（状态栏 + 浮动
        // 页头含进度卡）。
        body: Builder(
          builder: (BuildContext context) => _buildBody(
            context,
            total: total,
            popupResult: popupResult,
            gutter: gutter,
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required int total,
    required DictionarySearchResult? popupResult,
    required double gutter,
  }) {
    final double inset = MediaQuery.paddingOf(context).top;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 查词弹窗预览：结构恒定的尺寸动画外壳，结束后弹窗卸掉、外壳收起。
        AnimatedSize(
          duration: context.fushiMotion.spatialDefault.duration,
          curve: context.fushiMotion.spatialDefault.curve,
          alignment: Alignment.topCenter,
          child: popupResult == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  // 预览是固定不滚的 WebView（放进列表会被回收、打断批量
                  // 渲染等待），只能停在页头下方：顶部让出页头。
                  padding: EdgeInsets.fromLTRB(gutter, inset, gutter, 12),
                  child: FushiCard(
                    variant: FushiCardVariant.outlined,
                    padding: const EdgeInsets.all(4),
                    child: SizedBox(
                      height: _kPopupPreviewHeight,
                      // 只展示、不交互：批量流程自己取字段落卡，用户在这里点
                      // 「+」会与批量抢同一张卡。
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
                  ),
                ),
        ),
        Expanded(
          // 分段卡片列表：首尾大圆角、行间 2px；首屏错峰进场。
          child: FushiEntranceScope(
            child: ListView.builder(
              padding: withBottomSafeInset(
                context,
                // 无预览时列表滚到浮动页头底下（顶部让出页头）；有预览时
                // 预览已让过，列表紧接其下。
                EdgeInsets.fromLTRB(
                  gutter,
                  popupResult == null ? inset : 0,
                  gutter,
                  16,
                ),
              ),
              itemCount: total,
              itemBuilder: fushiStaggeredItemBuilder(
                (BuildContext context, int index) => FushiGroupedListItem(
                  index: index,
                  count: total,
                  child: _FavoriteBatchItemTile(
                    item: widget.items[index],
                    result: _results[index],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
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

/// 进度主卡：M3E primaryContainer 饱和色块 + Display 大数字 + 波浪进度条；
/// 完成后换成 tertiary 色块与汇总文案（颜色变化走 effects 弹簧）。
class _FavoriteBatchProgressCard extends StatelessWidget {
  const _FavoriteBatchProgressCard({
    required this.done,
    required this.total,
    required this.finished,
    required this.label,
  });

  final int done;
  final int total;
  final bool finished;
  final String label;

  @override
  Widget build(BuildContext context) {
    final FushiTypography type = context.fushiType;
    final double value = total == 0 ? 1 : done / total;
    final FushiCardTone tone = finished
        ? FushiCardTone.tertiary
        : FushiCardTone.primary;
    // 色块上的字跟卡片配对前景（fushiType 自带页面前景，HBK-AUDIT-022）。
    final Color? onCard = fushiCardToneColors(context, tone)?.onContainer;
    return FushiCard(
      tone: tone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              FushiIcon(
                finished
                    ? FushiIcons.filled(FushiIcons.success)
                    : FushiIcons.ankiCard,
              ),
              const SizedBox(width: 12),
              Text(
                '$done',
                style: type.displaySmallEmphasized.tabular.copyWith(
                  color: onCard,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text(
                  '/ $total',
                  style: type.titleMedium.tabular.copyWith(color: onCard),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(label, style: type.bodyMedium.copyWith(color: onCard)),
          const SizedBox(height: 12),
          TweenAnimationBuilder<double>(
            tween: Tween<double>(end: value),
            duration: context.fushiMotion.effectsDefault.duration,
            curve: context.fushiMotion.effectsDefault.curve,
            builder: (BuildContext context, double v, Widget? _) =>
                FushiLinearProgressIndicator(value: v),
          ),
        ],
      ),
    );
  }
}

class _FavoriteBatchItemTile extends StatelessWidget {
  const _FavoriteBatchItemTile({required this.item, required this.result});

  final FavoriteMiningItem item;
  final FavoriteBatchItemResult result;

  @override
  Widget build(BuildContext context) {
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
      leading: AnimatedSwitcher(
        duration: context.fushiMotion.effectsFast.duration,
        child: KeyedSubtree(
          key: ValueKey<FavoriteBatchItemStatus>(result.status),
          child: _statusIcon(context),
        ),
      ),
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

  /// 行首状态色块：成功 primary、重复 tertiary、失败 error、等待 / 跳过中性。
  Widget _statusIcon(BuildContext context) => switch (result.status) {
    FavoriteBatchItemStatus.pending => const FushiListLeadingIcon(
      FushiIcons.pending,
      tone: FushiCardTone.neutral,
    ),
    FavoriteBatchItemStatus.running => const SizedBox.square(
      dimension: 40,
      child: Padding(
        padding: EdgeInsets.all(8),
        child: FushiCircularProgressIndicator(strokeWidth: 3),
      ),
    ),
    FavoriteBatchItemStatus.added => FushiListLeadingIcon(
      result.textOnlyReason == null
          ? FushiIcons.filled(FushiIcons.success)
          : FushiIcons.success,
      tone: FushiCardTone.primary,
    ),
    FavoriteBatchItemStatus.duplicate => const FushiListLeadingIcon(
      FushiIcons.libraryAdd,
      tone: FushiCardTone.tertiary,
    ),
    FavoriteBatchItemStatus.failed => const FushiListLeadingIcon(
      FushiIcons.error,
      tone: FushiCardTone.error,
    ),
    FavoriteBatchItemStatus.skipped => const FushiListLeadingIcon(
      FushiIcons.block,
      tone: FushiCardTone.neutral,
    ),
  };
}
