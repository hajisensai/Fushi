import 'dart:io';

import 'package:fushi/src/media/source_library/add_local_folder_source.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/audio_cd/audio_cd_disc.dart';
import 'package:fushi_engine/media/audio_cd/audio_cd_ripper.dart';
import 'package:fushi_engine/media/audio_cd/windows_audio_cd_drive.dart';
import 'package:fushi_engine/media/media_extensions.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

/// 视频库导入入口的音频 CD 接管（BUG-3312）。
///
/// 音频 CD 在 Windows 上只露出 `TrackNN.cda` 快捷方式，里面没有音频，扫描器按扩展名
/// 白名单分类必然一条不收。所以在进扫描之前认出它：
/// - 不是音频 CD：返回 false，调用方照原流程走，行为逐字不变。
/// - Windows 光驱里的音频 CD：弹进度框抓轨到 `<documents>/audio_cd/`（同一张盘重插
///   复用，已抓的轨不重抓），再按「仅此一次」导入视频库（[importLocalFolderOnceAt]）；
///   取消 / 失败只提示。均返回 true，调用方刷新后结束。抓好的目录在数据根内，
///   不能登记成常驻来源（`MediaSources.rootPath` 只收数据根之外的外部目录）。
/// - `.cda` 不在光驱上（非 Windows，或从光盘拷出来的文件夹）：提示原因后返回 false，
///   照常扫描——子目录里可能还有真正的媒体文件。
Future<bool> importAudioCdIfPresent(
  BuildContext context, {
  required FushiDatabase db,
  required String dir,
}) async {
  if (!isAudioCdDirectory(dir)) return false;
  if (!Platform.isWindows || !isWindowsCdromPath(dir)) {
    FushiToast.show(
      msg: t.media_audio_cd_cda_unsupported,
      severity: ToastSeverity.warning,
    );
    return false;
  }
  // 'audio_cd' 登记在 AppPaths.fushiOwnedDocumentsEntries：数据根迁移时随根搬走。
  final Directory outputRoot = await AppPaths.documentsSubdirectory('audio_cd');
  if (!context.mounted) return true;
  final String? ripped = await showAppDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext _) =>
        AudioCdRipDialog(drivePath: dir, outputRoot: outputRoot.path),
  );
  if (ripped == null) return true;
  final SourceScanSummary? summary = await importLocalFolderOnceAt(
    db: db,
    mediaKind: SourceLibraryKind.video.dbValue,
    path: ripped,
    // 一张盘就是一张专辑：按文件夹成组，不按番剧系列去刮削。
    videoGroupingMode: 'folder',
  );
  final String? error = summary?.error;
  FushiToast.show(
    msg:
        error ??
        t.media_source_count_video(n: summary?.importedMediaCount ?? 0),
    severity: error == null ? ToastSeverity.success : ToastSeverity.error,
  );
  return true;
}

/// [dir] 的直接子文件是否构成一张音频 CD（见 [isAudioCdListing]）。读不了返回 false。
bool isAudioCdDirectory(String dir) {
  final List<String> names;
  try {
    names = <String>[
      for (final FileSystemEntity e in Directory(
        dir,
      ).listSync(followLinks: false))
        if (e is File) p.basename(e.path),
    ];
  } on FileSystemException {
    return false;
  }
  return isAudioCdListing(
    names,
    isImportableMedia: (String name) =>
        kVideoLibraryMediaExtensions.contains(p.extension(name).toLowerCase()),
  );
}

/// 抓轨进度对话框：打开即开始抓，完成后以抓好的目录出栈，取消 / 失败以 null 出栈。
///
/// 只能由抓轨自己结束：返回键 / 手柄 B 只触发取消（[PopScope]），等 worker 真正停下
/// 再出栈——否则旧 worker 还在写盘时用户就能重开一次，两次抓轨抢同一个 `.part`。
class AudioCdRipDialog extends StatefulWidget {
  const AudioCdRipDialog({
    super.key,
    required this.drivePath,
    required this.outputRoot,
  });

  final String drivePath;
  final String outputRoot;

  @override
  State<AudioCdRipDialog> createState() => _AudioCdRipDialogState();
}

class _AudioCdRipDialogState extends State<AudioCdRipDialog> {
  final AudioCdRipCancellation _cancellation = AudioCdRipCancellation();
  AudioCdRipProgress? _progress;

  @override
  void initState() {
    super.initState();
    _rip();
  }

  @override
  void dispose() {
    _cancellation.cancel();
    super.dispose();
  }

  Future<void> _rip() async {
    String? directory;
    try {
      final AudioCdRipResult? result = await ripAudioCd(
        drivePath: widget.drivePath,
        outputRoot: widget.outputRoot,
        cancellation: _cancellation,
        onProgress: (AudioCdRipProgress progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      directory = result?.directory;
      if (result != null && result.unreadableSectors > 0) {
        FushiToast.show(
          msg: t.media_audio_cd_rip_unreadable(n: result.unreadableSectors),
          severity: ToastSeverity.warning,
        );
      }
    } on Object catch (e, stack) {
      // 任何失败（无盘、弹盘、驱动拒读、写盘失败）都必须让对话框出栈，否则它不可关闭。
      ErrorLogService.instance.log('AudioCd.rip', e, stack);
      FushiToast.show(
        msg: t.media_audio_cd_rip_failed(
          error: e is AudioCdException ? e.message : '$e',
        ),
        severity: ToastSeverity.error,
      );
    }
    _close(directory);
  }

  /// 只移除本对话框这一条路由：抓轨要几分钟，期间别的页面可能被推到它上面
  /// （全局快捷键、悬浮反馈球），裸 `pop` 会弹掉那一页而把对话框留成关不掉的孤儿。
  void _close(String? directory) {
    if (!mounted) return;
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (route == null) return;
    final NavigatorState navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop(directory);
    } else {
      navigator.removeRoute(route, directory);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AudioCdRipProgress? progress = _progress;
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) setState(_cancellation.cancel);
      },
      child: AlertDialog(
        title: Text(t.media_audio_cd_rip_title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            LinearProgressIndicator(value: progress?.fraction),
            const SizedBox(height: 12),
            Text(
              progress == null
                  ? t.media_audio_cd_rip_reading
                  : t.media_audio_cd_rip_progress(
                      current: progress.trackIndex + 1,
                      total: progress.trackCount,
                    ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: _cancellation.isCancelled
                ? null
                : () => setState(_cancellation.cancel),
            child: Text(t.cancel),
          ),
        ],
      ),
    );
  }
}
