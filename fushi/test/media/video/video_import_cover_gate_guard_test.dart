import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

String _slice(String source, String startMarker, String endMarker) {
  final int start = source.indexOf(startMarker);
  expect(start, isNonNegative, reason: 'missing source marker: $startMarker');
  final int end = source.indexOf(endMarker, start + startMarker.length);
  expect(end, greaterThan(start), reason: 'missing end marker: $endMarker');
  return source.substring(start, end);
}

/// 按顺序在「掩注释 + 折叠空白」后的语料上找各步：`dart format` tall style
/// 会把实参折到下一行（如 `markAutoFrameAfterWrite(` 换行 `candidateUid,`），
/// 钉的是调用顺序而不是换行位置；折行带出的尾逗号（`,)`）同样归一掉。
/// 注释里的同名文字不算数。
void _expectOrdered(String source, List<String> markers) {
  final String code = compactCode(source).replaceAll(',)', ')');
  int previous = -1;
  for (final String rawMarker in markers) {
    final String marker = rawMarker
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(',)', ')');
    final int current = code.indexOf(marker, previous + 1);
    expect(
      current,
      greaterThan(previous),
      reason: 'expected marker after previous step: $marker',
    );
    previous = current;
  }
}

void main() {
  late String dialogSource;
  late String mainSource;

  setUpAll(() {
    dialogSource = File(
      'lib/src/media/video/video_import_dialog.dart',
    ).readAsStringSync();
    mainSource = File('lib/main.dart').readAsStringSync();
  });

  test('视频导入自动封面统一保持 operation -> mutation 锁顺序', () {
    final String gate = _slice(
      dialogSource,
      'Future<T> _runVideoImportCoverMutation<T>(',
      'Future<CoverMetaStore?> _admitAutoFrameCoverWrite(',
    );
    _expectOrdered(gate, <String>[
      'VideoScrapeOperationGate.tryEnterOperation()',
      'VideoCoverMutationGate.runExclusive<T>',
      'action(true)',
      'lease.release()',
    ]);
    expect(gate, contains('if (lease == null) return action(false)'));

    final String admission = _slice(
      dialogSource,
      'Future<CoverMetaStore?> _admitAutoFrameCoverWrite(',
      'Future<void> _commitAutoFrameCoverWrite(',
    );
    expect(admission, contains('allowsAutoFrameWrite(bookUid)'));
    final String commit = _slice(
      dialogSource,
      'Future<void> _commitAutoFrameCoverWrite(',
      // 原 end marker `String playlistBookUid(` 已随 video_library_import.dart
      // 搬进引擎包，在本文件里找不到 -> 切片直接失败（"missing end marker"）。
      // 换成本文件里紧随其后的下一个顶层函数，切片范围与从前一致。
      'Future<String> setVideoCoverFromPickedFile(',
    );
    expect(commit, contains('markAutoFrameAfterWrite(bookUid)'));
  });

  test('播放列表、单视频与流媒体把发布和指针提交留在统一临界区', () {
    final String playlist = _slice(
      dialogSource,
      'Future<void> _importPlaylistFromPath(',
      'Future<String> _uniqueBookUid(',
    );
    _expectOrdered(playlist, <String>[
      '_runVideoImportCoverMutation(',
      'importSplitPlaylist(',
      '_admitAutoFrameCoverWrite(',
      'extractPlaylistCover(',
      'updateCover(',
      '_commitAutoFrameCoverWrite(',
    ]);

    final String local = _slice(
      dialogSource,
      'Future<void> _doImport()',
      'bool get _streamUrlValid',
    );
    _expectOrdered(local, <String>[
      '_runVideoImportCoverMutation(',
      '_uniqueBookUid(',
      '_admitAutoFrameCoverWrite(',
      'extractVideoCover(',
      'saveVideoBook(',
      '_commitAutoFrameCoverWrite(',
    ]);

    // 流媒体导入的落库本体在门面 StreamVideoUrlImporter.importUrl（对话框与控制通道
    // 共用）；对话框的 _importStreamUrl 只经门面动手。
    final String stream = _slice(
      dialogSource,
      'Future<StreamVideoUrlImport> importUrl(',
      'Future<String?> _resolveYoutubeImportCover(',
    );
    _expectOrdered(stream, <String>[
      '_runVideoImportCoverMutation(',
      'uniqueVideoBookUid(',
      '_admitAutoFrameCoverWrite(',
      '_resolveYoutubeImportCover(',
      'saveVideoBook(',
      '_commitAutoFrameCoverWrite(',
    ]);
    expect(stream, contains('downloadCover: coverMetaStore != null'));
    final String dialogStream = _slice(
      dialogSource,
      'Future<void> _importStreamUrl(',
      'void _handleDialogDrop(',
    );
    expect(
      compactCode(dialogStream),
      contains('StreamVideoUrlImporter(widget.repo).importUrl('),
    );
    expect(dialogStream, isNot(contains('saveVideoBook(')));
  });

  test('YouTube 受保护或 maintenance 路径只取标题、不派生封面文件', () {
    final String youtube = _slice(
      dialogSource,
      'Future<String?> _resolveYoutubeImportCover(',
      'String _subtitleFileNameForUrl(',
    );
    _expectOrdered(youtube, <String>[
      'resolveYoutubeMetadata(url)',
      'if (!downloadCover) return null',
      'AppPaths.videoCoversDirectory()',
      'downloadVideoCoverToPath(',
    ]);
  });

  test('系统外部打开的新视频也原子提交自动封面', () {
    final String gate = _slice(
      mainSource,
      'Future<T> _runExternalVideoCoverMutation<T>(',
      'SystemUiOverlayStyle fushiSystemOverlayStyle(',
    );
    _expectOrdered(gate, <String>[
      'VideoScrapeOperationGate.tryEnterOperation()',
      'VideoCoverMutationGate.runExclusive<T>',
      'action(true)',
      'lease.release()',
    ]);
    expect(gate, contains('if (lease == null) return action(false)'));

    final String openExternal = _slice(
      mainSource,
      'Future<void> _openExternalVideo(',
      'void _scheduleWindowsUpdateHandoffReconcile()',
    );
    _expectOrdered(openExternal, <String>[
      '_runExternalVideoCoverMutation(',
      'findByVideoPath(',
      'allowsAutoFrameWrite(candidateUid)',
      'extractVideoCover(',
      'saveVideoBook(',
      'markAutoFrameAfterWrite(candidateUid)',
    ]);
  });
}
