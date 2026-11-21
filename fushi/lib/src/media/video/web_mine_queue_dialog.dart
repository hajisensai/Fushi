import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_mine_queue_dialog.dart'
    show mineQueueFailureText;
import 'package:fushi/src/mining/web_mine_queue_store.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_core/fushi_core.dart';

/// 网页视频页的「制卡队列」列表（拍板 design-nmv-webvideo-failed-retry 方案 a）：与本地视频
/// 「待制卡」同一套交互——待办行照常列出，失败行（视频到不了、录音 / 落卡失败、重复卡）红字
/// 带原因，可单行重试 / 移除；底部「全部重试」把失败行排回待办（跳过重复卡），「开始制卡」
/// 关掉列表交给页面开跑重放。
///
/// 本列表只动 DB（[WebMineQueueStore]），不碰播放器：重放必须由页面自己跑（它持有 WebView
/// 与录音）。返回 `true` = 用户点了「开始制卡」。只做显示 + 手动重试，不自动重试。
Future<bool> showWebMineQueueDialog({
  required BuildContext context,
  required WebMineQueueStore store,
  required String bookUid,
  required String Function(int pending) startLabel,
  VoidCallback? onChanged,
}) async {
  final bool? start = await showAppDialog<bool>(
    context: context,
    builder: (_) => WebMineQueueDialog(
      store: store,
      bookUid: bookUid,
      startLabel: startLabel,
      onChanged: onChanged,
    ),
  );
  return start ?? false;
}

/// 失败行能不能被「全部重试」排回去：重复卡不能（见 [WebMineQueueStore.requeueFailed]）。
bool webMineRowBatchRetryable(WebMineQueueRow row) =>
    row.status == WebMineQueueStatus.failed &&
    row.error != WebMineQueueStore.duplicateError;

/// 导出 widget 便于测试直接构造。
class WebMineQueueDialog extends StatefulWidget {
  const WebMineQueueDialog({
    required this.store,
    required this.bookUid,
    required this.startLabel,
    this.onChanged,
    super.key,
  });

  final WebMineQueueStore store;
  final String bookUid;

  /// 「开始制卡」按钮的文字，按当前待办张数给（窗口宿主档是「切到内置模式制作 N 张」）。
  final String Function(int pending) startLabel;

  /// 列表改了队列（重试 / 移除）：页面据此刷新角标。
  final VoidCallback? onChanged;

  @override
  State<WebMineQueueDialog> createState() => _WebMineQueueDialogState();
}

class _WebMineQueueDialogState extends State<WebMineQueueDialog> {
  List<WebMineQueueRow> _rows = const <WebMineQueueRow>[];
  bool _loading = true;

  /// 一次重试 / 移除在写库：期间按钮全灰，免得连点把同一行排两次。
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final List<WebMineQueueRow> failed = await widget.store.failed(
      widget.bookUid,
    );
    final List<WebMineQueueRow> pending = await widget.store.pending(
      widget.bookUid,
    );
    if (!mounted) return;
    setState(() {
      _rows = <WebMineQueueRow>[...failed, ...pending]
        ..sort((WebMineQueueRow a, WebMineQueueRow b) => a.id.compareTo(b.id));
      _loading = false;
    });
  }

  Future<void> _mutate(Future<Object?> Function() op) async {
    setState(() => _busy = true);
    try {
      await op();
    } finally {
      widget.onChanged?.call();
      await _reload();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retry(WebMineQueueRow row) =>
      _mutate(() => widget.store.requeueRow(row.id));

  Future<void> _remove(WebMineQueueRow row) =>
      _mutate(() => widget.store.remove(row.id));

  Future<void> _retryAll() =>
      _mutate(() => widget.store.requeueFailed(widget.bookUid));

  Widget _row(BuildContext context, WebMineQueueRow row) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Map<String, String> fields = decodeWebMineFields(row.fieldsJson);
    final String word = fields['expression'] ?? '';
    final bool failed = row.status == WebMineQueueStatus.failed;
    return FushiListItem(
      key: ValueKey<String>('web-mine-queue-${row.id}'),
      density: FushiListDensity.compact,
      title: Text(
        word.isEmpty ? row.sentence : word,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        failed
            ? t.video_mine_queue_failed(reason: mineQueueFailureText(row.error))
            : row.sentence,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: failed ? TextStyle(color: cs.error) : null,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 单行重试对重复卡也开放：用户点的是这一行，多半已在 Anki 里删了那张。
          if (failed)
            FushiIconButtonControl(
              key: ValueKey<String>('web-mine-queue-retry-${row.id}'),
              tooltip: t.web_video_mine_queue_retry,
              icon: const FushiIcon(FushiIcons.refresh),
              onPressed: _busy ? null : () => unawaited(_retry(row)),
            ),
          FushiIconButtonControl(
            key: ValueKey<String>('web-mine-queue-remove-${row.id}'),
            tooltip: t.video_mine_queue_remove,
            icon: const FushiIcon(FushiIcons.delete),
            onPressed: _busy ? null : () => unawaited(_remove(row)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final int pending = _rows
        .where((WebMineQueueRow r) => r.status == WebMineQueueStatus.pending)
        .length;
    final bool anyRetryable = _rows.any(webMineRowBatchRetryable);
    return FushiAlertDialog(
      title: Text(t.web_video_mine_queue_title),
      content: SizedBox(
        width: 520,
        child: _loading
            ? const FushiLoadingView()
            : _rows.isEmpty
            ? Text(t.web_video_mine_queue_empty)
            : FushiEntranceScope(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _rows.length,
                  itemBuilder: fushiStaggeredItemBuilder(
                    (BuildContext context, int index) =>
                        _row(context, _rows[index]),
                  ),
                ),
              ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.dialog_close),
        ),
        FushiTextButton(
          key: const ValueKey<String>('web-mine-queue-retry-all'),
          onPressed: _busy || !anyRetryable
              ? null
              : () => unawaited(_retryAll()),
          child: Text(t.web_video_mine_queue_retry_all),
        ),
        FushiFilledButton(
          key: const ValueKey<String>('web-mine-queue-start'),
          onPressed: _busy || pending == 0
              ? null
              : () => Navigator.of(context).pop(true),
          child: Text(widget.startLabel(pending)),
        ),
      ],
    );
  }
}
