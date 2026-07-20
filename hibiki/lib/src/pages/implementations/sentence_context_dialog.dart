import 'package:flutter/material.dart';
import 'package:hibiki/utils.dart';

/// BUG-763/766「制卡·选择句子上下文」**app 原生顶层对话框**。
///
/// 原实现把这个模态画在查词弹窗 WebView 内部（popup.js `openSentenceContextModal`），
/// 受弹窗表面的尺寸/半透明限制——句子框互相重叠、透出下面一层、在小弹窗里显示不全
/// （用户报「句子和句子之间是重叠的，有层透明」「这个是要顶层弹窗，不是查词弹窗内」）。
/// 改为真正的 Flutter 顶层对话框（[showAppDialog]），主题/焦点与 app 一致，句子框不再受
/// 弹窗表面约束。
///
/// 纯 UI + 三个注入回调，不持有任何宿主状态：
///   * [fetchPreview]：拉当前草稿的真实上下文预览（宿主 `onSentenceContextPreview*`，
///     结构 `{prev:[str], current:str, currentOffset:int?, next:[str], total:int}`）。
///   * [setContext]：把「上 prev 句 / 下 next 句」整体设进宿主草稿（`onSetSentenceContextToDraft`），
///     返回上下文句总数。**整体替换**语义（非累积）。
///   * [onConfirm]：确认制卡——回该词条的查词弹窗制卡按钮
///     （`DictionaryPopupWebViewState.mineEntryByIndex`，复用全部制卡/查重/覆写逻辑）。
class SentenceContextDialog extends StatefulWidget {
  const SentenceContextDialog({
    super.key,
    required this.matched,
    required this.fetchPreview,
    required this.setContext,
    required this.onConfirm,
  });

  /// 查到的词表现形，用于在「当前句」里高亮（失配回退 indexOf，再失配无高亮）。
  final String matched;

  /// 拉当前草稿的真实上下文预览。
  final Future<Map<String, Object?>> Function() fetchPreview;

  /// 把「上 prev 句 / 下 next 句」整体设进宿主草稿，返回上下文句总数。
  final Future<int> Function(int prev, int next) setContext;

  /// 确认制卡（回该词条 WebView 制卡按钮）。
  final VoidCallback onConfirm;

  @override
  State<SentenceContextDialog> createState() => _SentenceContextDialogState();
}

class _SentenceContextDialogState extends State<SentenceContextDialog> {
  List<String> _prev = const <String>[];
  List<String> _next = const <String>[];
  String _current = '';
  int? _currentOffset;
  int _total = 0;
  bool _busy = false;
  bool _loading = true;

  // 打开时的上下文快照，取消时还原——对齐旧 JS 模态 cancel 语义：取消不把半调整的草稿
  // 留给后续「一键 +」制卡。
  int _snapPrev = 0;
  int _snapNext = 0;
  bool _snapped = false;

  // 到边界（请求更多但宿主返回句数不再增长，段落/章/文首文尾封顶）时禁用对应「+」，
  // 给诚实反馈（不再点了没反应）。
  bool _prevAtMax = false;
  bool _nextAtMax = false;

  @override
  void initState() {
    super.initState();
    _refresh(initial: true);
  }

  static List<String> _stringList(Object? v) => v is List
      ? <String>[for (final Object? e in v) e.toString()]
      : const <String>[];

  Future<void> _refresh({bool initial = false}) async {
    final Map<String, Object?> p = await widget.fetchPreview();
    if (!mounted) return;
    setState(() {
      _prev = _stringList(p['prev']);
      _next = _stringList(p['next']);
      _current = p['current'] as String? ?? '';
      _currentOffset = (p['currentOffset'] as num?)?.toInt();
      _total = (p['total'] as num?)?.toInt() ?? (_prev.length + _next.length);
      if (initial && !_snapped) {
        _snapPrev = _prev.length;
        _snapNext = _next.length;
        _snapped = true;
      }
      _loading = false;
    });
  }

  Future<void> _adjust({required bool prevDir, required bool plus}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final int curPrev = _prev.length;
      final int curNext = _next.length;
      final int newPrev = prevDir
          ? (plus ? curPrev + 1 : (curPrev > 0 ? curPrev - 1 : 0))
          : curPrev;
      final int newNext = !prevDir
          ? (plus ? curNext + 1 : (curNext > 0 ? curNext - 1 : 0))
          : curNext;
      final int before = prevDir ? curPrev : curNext;
      await widget.setContext(newPrev, newNext);
      await _refresh();
      if (!mounted) return;
      final int after = prevDir ? _prev.length : _next.length;
      setState(() {
        if (prevDir) {
          _prevAtMax = plus && after <= before;
        } else {
          _nextAtMax = plus && after <= before;
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    // 还原到打开时的上下文。setContext 失败尽力而为，仍关窗。
    try {
      await widget.setContext(_snapPrev, _snapNext);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  void _confirm() {
    Navigator.of(context).pop();
    widget.onConfirm();
  }

  /// 当前句里把查到的词高亮：offset 命中优先（offset 处正好是 matched），失配回退
  /// indexOf，再失配整句无高亮——与旧 popup.js `buildHighlightedCurrentText` 同容错。
  Widget _highlightedCurrent(ThemeData theme) {
    final String text = _current;
    final String matched = widget.matched;
    final ColorScheme scheme = theme.colorScheme;
    // 当前句整句半粗（对齐 Niratan `.body.weight(.semibold)`），命中词再加重 + 底色。
    final TextStyle base = (theme.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(fontWeight: FontWeight.w500);
    final TextStyle hl = base.copyWith(
      color: scheme.primary,
      fontWeight: FontWeight.w700,
      backgroundColor: scheme.primary.withValues(alpha: 0.30),
    );
    if (text.isEmpty) {
      return Text('', style: base);
    }
    int start = -1;
    if (matched.isNotEmpty) {
      final int? off = _currentOffset;
      if (off != null &&
          off >= 0 &&
          off + matched.length <= text.length &&
          text.substring(off, off + matched.length) == matched) {
        start = off;
      } else {
        start = text.indexOf(matched);
      }
    }
    if (start < 0) {
      return Text(text, style: base);
    }
    return Text.rich(
      TextSpan(
        style: base,
        children: <TextSpan>[
          TextSpan(text: text.substring(0, start)),
          TextSpan(
              text: text.substring(start, start + matched.length), style: hl),
          TextSpan(text: text.substring(start + matched.length)),
        ],
      ),
    );
  }

  Widget _box(
    ThemeData theme, {
    required String label,
    required Widget child,
    bool current = false,
  }) {
    final ColorScheme scheme = theme.colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    // 走共享 MD3 卡片外壳（HibikiCard）而非裸 Container+BoxDecoration：
    // 当前句用更高一档的容器令牌 surfaces.search + primary 描边区分，上/下句用
    // surfaces.card。非当前句保留 transparent 1px 描边，令内容起点严格对齐
    // （等价旧的透明 Border.all，避免仅当前句多 1px 内缩）。对齐 Niratan 原设计：
    // 当前句留白更足（12）、上下文句收一档（10）。
    final Widget card = HibikiCard(
      padding:
          EdgeInsets.symmetric(horizontal: 12, vertical: current ? 12 : 10),
      color: current ? tokens.surfaces.search : tokens.surfaces.card,
      borderColor: current ? tokens.surfaces.primary : Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
    if (current) return card;
    // 非当前句略缩略淡，做出「当前句浮在上下文之上」的层次（Niratan 卡叠效果）。
    return Opacity(
      opacity: 0.82,
      child: Transform.scale(scale: 0.975, child: card),
    );
  }

  Widget _sentenceText(ThemeData theme, String sentence) =>
      Text(sentence, style: theme.textTheme.bodyMedium);

  Widget _emptyText(ThemeData theme) => Text(
        t.popup_ctx_box_empty,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontStyle: FontStyle.italic,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );

  /// 把某个方向的句子列表铺成「一句一张卡」——不再 `join('\n')` 把整方向挤进一个框
  /// （旧写法在前文有重复/多句时糊成一坨、看不出边界）。空列表退化成一张「(无)」卡，
  /// 保留该方向标签的存在感。对齐目标设计：每条上下文句独立成卡、各带方向标签。
  List<Widget> _directionCards(
    ThemeData theme, {
    required String label,
    required List<String> sentences,
  }) {
    if (sentences.isEmpty) {
      return <Widget>[_box(theme, label: label, child: _emptyText(theme))];
    }
    return <Widget>[
      for (final String s in sentences)
        _box(theme, label: label, child: _sentenceText(theme, s)),
    ];
  }

  /// ±上下文按钮：图标（−/+）+ 文案的描边按钮。保持 [OutlinedButton] 语义。
  /// 收紧到 compact 视觉密度 + 收敛内边距/最小尺寸——横屏矮窗里四颗按钮占位太重
  /// （用户报「这个选项占位太大」），压扁后给句子预览让出竖向空间。
  Widget _adjustButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) =>
      OutlinedButton.icon(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          minimumSize: const Size(0, 36),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: Icon(icon, size: 18),
        label: Text(label),
      );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    // 一句一卡：前文各句 → 当前句（高亮卡）→ 后文各句，卡间统一 6px 留白。
    final List<Widget> cards = <Widget>[
      ..._directionCards(theme, label: t.popup_ctx_box_prev, sentences: _prev),
      _box(
        theme,
        label: t.popup_ctx_box_current,
        current: true,
        child: _highlightedCurrent(theme),
      ),
      ..._directionCards(theme, label: t.popup_ctx_box_next, sentences: _next),
    ];
    final List<Widget> spacedCards = <Widget>[];
    for (int i = 0; i < cards.length; i++) {
      if (i > 0) spacedCards.add(const SizedBox(height: 6));
      spacedCards.add(cards[i]);
    }

    return AlertDialog(
      // BUG-922：横屏矮窗里正文竖向空间不足时，旧的 `Flexible(SingleChildScrollView)`
      // 会把整块滚动区让给固定的计数/按钮区、塌成 0 高——句子预览整段消失，只剩选项
      // （用户报「手机上看不见句子，只有选项」）。改为让整个对话框正文可滚动
      // （`scrollable: true` + 正文直接铺卡，不再嵌 Flexible），任何朝向/尺寸下句子预览
      // 都保有真实高度、按需滚动，不再塌陷也不溢出。
      scrollable: true,
      // 标题区对齐 Niratan header：小 eyebrow 在上、大标题在下，右侧一个关闭 X（=取消）。
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t.popup_ctx_modal_eyebrow,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 3),
                Text(t.popup_ctx_modal_title),
              ],
            ),
          ),
          IconButton(
            tooltip: t.popup_ctx_cancel,
            onPressed: _busy ? null : _cancel,
            icon: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: _loading
            ? const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      t.popup_ctx_modal_count.replaceAll('%d', '$_total'),
                      style: theme.textTheme.labelLarge
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  // 正文已由 AlertDialog(scrollable: true) 统一滚动，这里直接铺卡，
                  // 不再嵌 Flexible/SingleChildScrollView（那在矮窗会塌成 0 高）。
                  ...spacedCards,
                  const SizedBox(height: 12),
                  // ±上下文：前一组靠左、后一组靠右（对齐 Niratan rangeControls 的
                  // 「Remove/Add Previous … Remove/Add Next」分组）。各半区内用 Wrap
                  // 兜底换行，窄屏不会溢出。
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: <Widget>[
                            _adjustButton(
                              icon: Icons.remove,
                              label: t.popup_ctx_prev_minus,
                              onPressed: _busy || _prev.isEmpty
                                  ? null
                                  : () => _adjust(prevDir: true, plus: false),
                            ),
                            _adjustButton(
                              icon: Icons.add,
                              label: t.popup_ctx_prev_plus,
                              onPressed: _busy || _prevAtMax
                                  ? null
                                  : () => _adjust(prevDir: true, plus: true),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.end,
                          children: <Widget>[
                            _adjustButton(
                              icon: Icons.remove,
                              label: t.popup_ctx_next_minus,
                              onPressed: _busy || _next.isEmpty
                                  ? null
                                  : () => _adjust(prevDir: false, plus: false),
                            ),
                            _adjustButton(
                              icon: Icons.add,
                              label: t.popup_ctx_next_plus,
                              onPressed: _busy || _nextAtMax
                                  ? null
                                  : () => _adjust(prevDir: false, plus: true),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
      // 底部动作对齐 Niratan footer：右下角 Cancel + Confirm Mining（主按钮）。
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : _cancel,
          child: Text(t.popup_ctx_cancel),
        ),
        FilledButton(
          autofocus: true,
          onPressed: _busy ? null : _confirm,
          child: Text(t.popup_ctx_confirm),
        ),
      ],
    );
  }
}
