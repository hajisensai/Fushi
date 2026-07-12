import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';

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
    final TextStyle base = theme.textTheme.bodyMedium ?? const TextStyle();
    final TextStyle hl = base.copyWith(
      color: scheme.primary,
      fontWeight: FontWeight.w600,
      backgroundColor: scheme.primary.withValues(alpha: 0.18),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: current ? scheme.surfaceContainerHigh : scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: current ? scheme.primary : Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 3),
          child,
        ],
      ),
    );
  }

  Widget _sentencesText(ThemeData theme, List<String> sentences) {
    if (sentences.isEmpty) {
      return Text(
        t.popup_ctx_box_empty,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontStyle: FontStyle.italic,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Text(sentences.join('\n'), style: theme.textTheme.bodyMedium);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      title: Text(t.popup_ctx_modal_title),
      content: SizedBox(
        width: 420,
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
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          _box(
                            theme,
                            label: t.popup_ctx_box_prev,
                            child: _sentencesText(theme, _prev),
                          ),
                          const SizedBox(height: 8),
                          _box(
                            theme,
                            label: t.popup_ctx_box_current,
                            current: true,
                            child: _highlightedCurrent(theme),
                          ),
                          const SizedBox(height: 8),
                          _box(
                            theme,
                            label: t.popup_ctx_box_next,
                            child: _sentencesText(theme, _next),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      OutlinedButton(
                        onPressed: _busy || _prev.isEmpty
                            ? null
                            : () => _adjust(prevDir: true, plus: false),
                        child: Text(t.popup_ctx_prev_minus),
                      ),
                      OutlinedButton(
                        onPressed: _busy || _prevAtMax
                            ? null
                            : () => _adjust(prevDir: true, plus: true),
                        child: Text(t.popup_ctx_prev_plus),
                      ),
                      OutlinedButton(
                        onPressed: _busy || _next.isEmpty
                            ? null
                            : () => _adjust(prevDir: false, plus: false),
                        child: Text(t.popup_ctx_next_minus),
                      ),
                      OutlinedButton(
                        onPressed: _busy || _nextAtMax
                            ? null
                            : () => _adjust(prevDir: false, plus: true),
                        child: Text(t.popup_ctx_next_plus),
                      ),
                    ],
                  ),
                ],
              ),
      ),
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
