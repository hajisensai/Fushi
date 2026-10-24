import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_page_common.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/reveal_in_file_manager.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_tab_view.dart'
    show openWebBrowserDownloadedFile;
import 'package:fushi/utils.dart';

/// 打开一个本地文件（默认交给 [openWebBrowserDownloadedFile]）。
typedef WebBrowserFileOpener = Future<void> Function(String path);

/// 在文件管理器里定位（默认 [revealInFileManager]）；返回 false = 失败。
typedef WebBrowserFileRevealer = Future<bool> Function(String path);

/// 浏览器下载记录：进度、打开文件、在文件夹中显示（桌面）、删除记录。
class WebBrowserDownloadsPage extends StatefulWidget {
  const WebBrowserDownloadsPage({
    required this.store,
    this.openFile = openWebBrowserDownloadedFile,
    this.revealFile,
    this.fileExists,
    super.key,
  });

  final WebBrowserStore store;
  final WebBrowserFileOpener openFile;

  /// null = 按平台取（移动端没有文件管理器，入口整条隐藏）。
  final WebBrowserFileRevealer? revealFile;

  /// 测试注入；null = 查真实文件系统。
  final bool Function(String path)? fileExists;

  @override
  State<WebBrowserDownloadsPage> createState() =>
      _WebBrowserDownloadsPageState();
}

enum _DownloadAction { open, reveal, remove }

class _WebBrowserDownloadsPageState extends State<WebBrowserDownloadsPage> {
  List<WebBrowserDownload> _items = const <WebBrowserDownload>[];
  bool _loading = true;
  int _loadGeneration = 0;
  int _replay = 0;

  WebBrowserFileRevealer? get _revealer =>
      widget.revealFile ??
      (currentRevealHost() == null ? null : revealInFileManager);

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreChanged);
    unawaited(_load(replay: true));
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() => unawaited(_load());

  Future<void> _load({bool replay = false}) async {
    final int generation = ++_loadGeneration;
    final List<WebBrowserDownload> items = await widget.store.downloads();
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _items = items;
      _loading = false;
      if (replay) _replay++;
    });
  }

  bool _exists(String path) =>
      (widget.fileExists ?? (String p) => File(p).existsSync())(path);

  Future<void> _openFile(WebBrowserDownload d) async {
    final String? path = d.savedPath;
    if (path == null) return;
    if (!_exists(path)) {
      showWebBrowserPageSnack(context, t.web_browser_download_file_missing);
      return;
    }
    try {
      await widget.openFile(path);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'WebBrowserDownloadsPage.open',
        error,
        stack,
      );
      if (mounted) {
        showWebBrowserPageSnack(context, t.web_browser_download_open_failed);
      }
    }
  }

  Future<void> _reveal(WebBrowserDownload d) async {
    final String? path = d.savedPath;
    final WebBrowserFileRevealer? reveal = _revealer;
    if (path == null || reveal == null) return;
    final bool ok = await reveal(path);
    if (!ok && mounted) {
      showWebBrowserPageSnack(context, t.web_browser_download_file_missing);
    }
  }

  Future<void> _onAction(WebBrowserDownload d, _DownloadAction action) async {
    switch (action) {
      case _DownloadAction.open:
        await _openFile(d);
      case _DownloadAction.reveal:
        await _reveal(d);
      case _DownloadAction.remove:
        await widget.store.deleteDownload(d.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: t.web_browser_downloads_title,
      body: _loading
          ? const Center(child: FushiCircularProgressIndicator())
          : webBrowserPageListView(
              replayKey: _replay,
              key: const ValueKey<String>('web_browser_downloads_list'),
              children: <Widget>[
                if (_items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(child: Text(t.web_browser_downloads_empty)),
                  )
                else
                  FushiStaggeredEntrance(
                    index: 0,
                    child: FushiGroupedList(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: <Widget>[
                        for (final WebBrowserDownload d in _items) _tile(d),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  String _status(WebBrowserDownload d) {
    final int? total = d.totalBytes;
    return switch (d.state) {
      WebBrowserDownloadState.running =>
        total == null || total <= 0
            ? FushiByteFormat.bytes(d.receivedBytes)
            : t.web_browser_download_progress(
                received: FushiByteFormat.bytes(d.receivedBytes),
                total: FushiByteFormat.bytes(total),
              ),
      WebBrowserDownloadState.completed => FushiByteFormat.bytes(
        total ?? d.receivedBytes,
      ),
      WebBrowserDownloadState.failed => t.web_browser_download_state_failed,
      WebBrowserDownloadState.cancelled =>
        t.web_browser_download_state_cancelled,
    };
  }

  Widget _tile(WebBrowserDownload d) {
    final bool done =
        d.state == WebBrowserDownloadState.completed && d.savedPath != null;
    final int? total = d.totalBytes;
    final double? progress = total == null || total <= 0
        ? null
        : (d.receivedBytes / total).clamp(0.0, 1.0);
    final String host = d.url.host;
    return FushiListItem(
      key: ValueKey<String>('web_browser_download_${d.id}'),
      leading: FushiListLeadingIcon(switch (d.state) {
        WebBrowserDownloadState.running => FushiIcons.downloading,
        WebBrowserDownloadState.completed => FushiIcons.file,
        WebBrowserDownloadState.failed => FushiIcons.error,
        WebBrowserDownloadState.cancelled => FushiIcons.cancel,
      }),
      title: Text(d.fileName),
      subtitle: d.state == WebBrowserDownloadState.running
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: FushiLinearProgressIndicator(value: progress),
                ),
                Text(_status(d)),
              ],
            )
          : Text(host.isEmpty ? _status(d) : '${_status(d)} · $host'),
      subtitleMaxLines: 1,
      onTap: done ? () => unawaited(_openFile(d)) : null,
      trailing: FushiOverflowMenu<_DownloadAction>(
        key: ValueKey<String>('web_browser_download_menu_${d.id}'),
        tooltip: t.common_more_actions,
        onSelected: (_DownloadAction a) => unawaited(_onAction(d, a)),
        items: <PopupMenuEntry<_DownloadAction>>[
          if (done)
            FushiPopupMenuItem<_DownloadAction>(
              value: _DownloadAction.open,
              label: t.web_browser_download_open,
              icon: FushiIcons.openInNew,
            ),
          if (done && _revealer != null)
            FushiPopupMenuItem<_DownloadAction>(
              value: _DownloadAction.reveal,
              label: t.download_task_open_location,
              icon: FushiIcons.folderOpen,
            ),
          FushiPopupMenuItem<_DownloadAction>(
            value: _DownloadAction.remove,
            label: t.web_browser_download_remove,
            icon: FushiIcons.delete,
          ),
        ],
      ),
    );
  }
}
