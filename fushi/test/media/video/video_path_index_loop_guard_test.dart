// 源码守卫（video-36k）：对一批路径逐个判重 / 认行的循环必须先建一次
// [VideoPathIndex]，不能在循环里逐个 `findByVideoPath`——后者每次都整表读
// 视频行再逐行归一，N 个文件就是 N 次整表读 + N×M 次归一。
//
// 拖入合集（media_collection_detail_page.dart）在 c16 已改；这里钉剩下两处
// 同形循环：下载任务导入后认行归来源、删下载计划时清掉已入库行。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relative) {
  final List<String> candidates = <String>[relative, '../$relative'];
  for (final String path in candidates) {
    final File file = File(path);
    if (file.existsSync()) return file.readAsStringSync();
  }
  throw StateError('source not found: $relative');
}

void main() {
  test('download pipeline maps imported files through one path index', () {
    final String src = _read(
      'packages/fushi_engine/lib/media/video/download/'
      'video_download_pipeline_service.dart',
    );
    expect(src, isNot(contains('findByVideoPath(')));
    expect(src, contains('await _videoRepository.videoPathIndex()'));
  });

  test('anime plan delete resolves deleted files through one path index', () {
    final String src = _read(
      'fushi/lib/src/pages/implementations/anime_download_dialog.dart',
    );
    expect(src, isNot(contains('findByVideoPath(')));
    expect(src, contains('await repo.videoPathIndex()'));
    // 不同写法的路径归一到同一行时只删一次。
    expect(src, contains('deleted.add(row.bookUid)'));
  });
}
