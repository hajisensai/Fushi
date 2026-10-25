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

/// 排版无关的代码语料：注释掩掉、空白折叠，`dart format` 拆行时补的尾逗号
/// （`f(\n  a,\n)` → `f(a,)`）也去掉，只剩调用本身的形态。
String _layoutFree(String source) =>
    compactCode(source).replaceAll(RegExp(r',(?=[)\]}])'), '');

/// 按顺序在**代码**里找 [markers]：`dart format` 把调用拆行（如
/// `markAutoFrameAfterWrite(\n  candidateUid,\n)`）不改变判据，注释里写着同名
/// 调用也不算数。
void _expectOrdered(String source, List<String> markers) {
  final String code = _layoutFree(source);
  int previous = -1;
  for (final String marker in markers) {
    final int current = code.indexOf(_layoutFree(marker), previous + 1);
    expect(
      current,
      greaterThan(previous),
      reason: 'expected marker after previous step: $marker',
    );
    previous = current;
  }
}

/// [source] 的代码（注释掩掉、空白折叠后）是否含 [needle]。
void _expectCodeContains(String source, String needle) {
  expect(
    _layoutFree(source),
    contains(_layoutFree(needle)),
    reason: 'missing code: $needle',
  );
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
    _expectCodeContains(gate, 'if (lease == null) return action(false)');

    final String admission = _slice(
      dialogSource,
      'Future<CoverMetaStore?> _admitAutoFrameCoverWrite(',
      'Future<void> _commitAutoFrameCoverWrite(',
    );
    _expectCodeContains(admission, 'allowsAutoFrameWrite(bookUid)');
    final String commit = _slice(
      dialogSource,
      'Future<void> _commitAutoFrameCoverWrite(',
      // 原 end marker `String playlistBookUid(` 已随 video_library_import.dart
      // 搬进引擎包，在本文件里找不到 -> 切片直接失败（"missing end marker"）。
      // 换成本文件里紧随其后的下一个顶层函数，切片范围与从前一致。
      'Future<String> setVideoCoverFromPickedFile(',
    );
    _expectCodeContains(commit, 'markAutoFrameAfterWrite(bookUid)');
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

    final String stream = _slice(
      dialogSource,
      'Future<void> _importStreamUrl(',
      'Future<String?> _resolveYoutubeImportCover(',
    );
    _expectOrdered(stream, <String>[
      '_runVideoImportCoverMutation(',
      '_uniqueBookUid(',
      '_admitAutoFrameCoverWrite(',
      '_resolveYoutubeImportCover(',
      'saveVideoBook(',
      '_commitAutoFrameCoverWrite(',
    ]);
    _expectCodeContains(stream, 'downloadCover: coverMetaStore != null');
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
    _expectCodeContains(gate, 'if (lease == null) return action(false)');

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
