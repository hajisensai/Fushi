import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_engine/media/video/m3u8_playlist.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/import/import_dialog_frame.dart';
import 'package:fushi/src/media/import/import_flow_mixin.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/video/iptv_playlist_import.dart';
import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/utils.dart';

/// [IptvPlaylistImportDialog] 关窗时交回的结果。
sealed class IptvPlaylistImportOutcome {
  const IptvPlaylistImportOutcome();
}

/// 频道列表已入库。
class IptvPlaylistImported extends IptvPlaylistImportOutcome {
  const IptvPlaylistImported(this.result);

  final IptvPlaylistImportResult result;
}

/// 填进来的其实是一条 HLS 流（media / master playlist）：不拆频道，交给调用方
/// 按单个视频导入（远端 = 流链接导入，本地 = 视频文件导入）。
class IptvPlaylistIsHlsStream extends IptvPlaylistImportOutcome {
  const IptvPlaylistIsHlsStream({this.url, this.localPath});

  final String? url;
  final String? localPath;
}

/// 「导入 IPTV / M3U 频道列表」对话框：填列表 URL 或选本地 `.m3u` / `.m3u8`。
///
/// 频道列表按 [importIptvChannels] 拆成流条目 + playlist 合集入库（与拖入 m3u
/// 清单同一存储形状）；HLS 流清单不拆，交回 [IptvPlaylistIsHlsStream]。
class IptvPlaylistImportDialog extends StatefulWidget {
  const IptvPlaylistImportDialog({required this.repo, super.key});

  final VideoBookRepository repo;

  @override
  State<IptvPlaylistImportDialog> createState() =>
      _IptvPlaylistImportDialogState();
}

class _IptvPlaylistImportDialogState extends State<IptvPlaylistImportDialog>
    with ImportFlowMixin<IptvPlaylistImportDialog> {
  final TextEditingController _urlController = TextEditingController();
  String? _localPath;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  bool get _urlValid => isPlayableStreamUrl(_urlController.text);

  bool get _canImport => !importing && (_urlValid || _localPath != null);

  Future<void> _pickFile() async {
    final String? path = await pickSystemFilePath(
      context: context,
      allowedExtensions: const <String>{'m3u', 'm3u8'},
    );
    if (path == null || !mounted) return;
    setState(() => _localPath = path);
  }

  Future<void> _doImport() async {
    if (!_canImport) return;
    final String url = _urlController.text.trim();
    final String? localPath = _urlValid ? null : _localPath;
    final AppModel appModel =
        ProviderScope.containerOf(context, listen: false).read(appProvider);
    await runImport(
      logTag: 'IptvPlaylistImportDialog.import',
      action: () async {
        final IptvPlaylistSource source = localPath != null
            ? await readLocalIptvPlaylist(localPath)
            : await fetchRemoteIptvPlaylist(url);
        // 与导入同一基址判：远端列表里被解析层拒收的本地条目不算频道。
        switch (classifyM3uPlaylist(source.content, baseDir: source.baseDir)) {
          case M3uPlaylistKind.hlsStream:
            if (!mounted) return;
            Navigator.pop(
              context,
              IptvPlaylistIsHlsStream(url: source.url, localPath: localPath),
            );
            return;
          case M3uPlaylistKind.empty:
            if (mounted) {
              FushiToast.show(
                msg: t.video_iptv_list_empty,
                severity: ToastSeverity.warning,
              );
            }
            return;
          case M3uPlaylistKind.channelList:
            break;
        }
        final List<M3uChannel> channels = parseM3uChannels(
          content: source.content,
          baseDir: source.baseDir,
        );
        final IptvPlaylistImportResult result = await importIptvChannels(
          db: appModel.database,
          repo: widget.repo,
          source: source,
          channels: channels,
        );
        final String? firstUid = result.firstBookUid;
        if (firstUid != null) {
          await widget.repo.recordVideoImportActivity(
            bookUid: firstUid,
            title: source.listName,
          );
        }
        // 台标封面是 best-effort 的后台增强：几百个频道逐个下载不该挡住关窗。
        // 同一列表再导入时取消上一路还没跑完的台标任务（beginIptvLogoJob）。
        unawaited(
          applyIptvChannelLogos(
            repo: widget.repo,
            source: source,
            channels: channels,
            cancelToken: beginIptvLogoJob(source.sourceKey),
          ).catchError((Object e) {
            debugPrint('[iptv-import] channel logos failed: $e');
            return 0;
          }),
        );
        if (!mounted) return;
        FushiToast.show(
          msg: t.video_iptv_imported(count: result.channelCount),
          severity: ToastSeverity.success,
        );
        Navigator.pop(context, IptvPlaylistImported(result));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ImportDialogFrame(
      leadingIcon: Icons.live_tv_outlined,
      title: t.video_iptv_import_title,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiTextFieldControl(
            controller: _urlController,
            enabled: !importing,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: t.video_iptv_url_field,
              hintText: 'https://.../playlist.m3u',
              prefixIcon: const FushiIcon(Icons.link),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_canImport) _doImport();
            },
          ),
          const SizedBox(height: 8),
          FushiOutlinedButton.icon(
            onPressed: importing ? null : _pickFile,
            icon: const FushiIcon(Icons.playlist_play_outlined),
            label: Text(
              _localPath == null
                  ? t.video_iptv_pick_file
                  : p.basename(_localPath!),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t.video_iptv_import_hint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: importing ? null : () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        buildImportAction(
          context,
          onImport: () {
            if (_canImport) _doImport();
          },
        ),
      ],
    );
  }
}
