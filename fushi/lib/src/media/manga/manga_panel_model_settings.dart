import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fushi/src/media/manga/manga_panel_model_service.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/manga/panel_model_manifest.dart';

class MangaPanelModelSettings extends StatefulWidget {
  const MangaPanelModelSettings({super.key});

  @override
  State<MangaPanelModelSettings> createState() =>
      _MangaPanelModelSettingsState();
}

class _MangaPanelModelSettingsState extends State<MangaPanelModelSettings> {
  MangaPanelModelStatus? _status;
  StreamSubscription<int>? _download;
  int _received = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    unawaited(_download?.cancel());
    super.dispose();
  }

  Future<void> _refresh() async {
    final MangaPanelModelStatus status = await mangaPanelModelStatus();
    if (mounted) setState(() => _status = status);
  }

  void _downloadModel() {
    if (_busy) return;
    setState(() {
      _busy = true;
      _received = 0;
    });
    _download = downloadMangaPanelModel().listen(
      (int value) {
        if (mounted) setState(() => _received = value);
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() => _busy = false);
        final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
        messenger.showSnackBar(
          SnackBar(
            content: Text(t.manga_panel_model_download_failed(error: '$error')),
          ),
        );
      },
      onDone: () async {
        if (!mounted) return;
        setState(() => _busy = false);
        await _refresh();
      },
    );
  }

  Future<void> _deleteModel() async {
    final FileStatus status = await _modelFileStatus();
    if (!status.exists) return;
    await status.file.delete();
    if (mounted) await _refresh();
  }

  Future<FileStatus> _modelFileStatus() async {
    final file = await mangaPanelModelFile();
    return FileStatus(file, await file.exists());
  }

  @override
  Widget build(BuildContext context) {
    final MangaPanelModelStatus? status = _status;
    final bool verified = status?.available ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        FushiListItem(
          // 裸 ListTile 会被 MD3 守卫（md3_design_system_static_test）判违规：
          // 普通页面 chrome 一律走共享组件，本仓把 ListTile 整体收口到了它。
          title: Text(t.manga_panel_model),
          subtitle: Text(
            _busy
                ? t.manga_panel_model_downloading_bytes(bytes: '$_received')
                : status?.error ??
                      (verified
                          ? t.manga_panel_model_ready
                          : t.manga_panel_model_missing),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (verified)
                IconButton(
                  tooltip: t.manga_panel_model_delete,
                  onPressed: _busy ? null : _deleteModel,
                  icon: const Icon(Icons.delete_outline),
                ),
              FilledButton(
                onPressed: _busy || verified ? null : _downloadModel,
                child: Text(
                  _busy
                      ? t.manga_panel_model_downloading
                      : t.manga_panel_model_download,
                ),
              ),
            ],
          ),
        ),
        if (_busy)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value:
                  kMangaPanelModelBytes == null || kMangaPanelModelBytes! <= 0
                  ? null
                  : (_received / kMangaPanelModelBytes!).clamp(0.0, 1.0),
            ),
          ),
      ],
    );
  }
}

class FileStatus {
  const FileStatus(this.file, this.exists);
  final File file;
  final bool exists;
}
