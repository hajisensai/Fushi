import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';

/// 取 [signature] 起到其方法体闭合 `}` 的源码（签名本身不含 `{`）。
String _methodBody(String source, String signature) {
  final int start = source.indexOf(signature);
  if (start < 0) throw StateError('missing method signature: $signature');
  final int bodyStart = source.indexOf('{', start + signature.length);
  int depth = 0;
  for (int i = bodyStart; i >= 0 && i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(start, i + 1);
    }
  }
  throw StateError('unterminated method body: $signature');
}

void main() {
  final String page = readVideoFushiSource();

  group('TODO-434 远端视频片段导出守卫', () {
    test('远端直连流只提示先下载，不进入片段导出状态', () {
      final int idx = page.indexOf('Future<void> _toggleClipExport(');
      expect(
        idx,
        greaterThanOrEqualTo(0),
        reason: '片段导出入口应统一走 _toggleClipExport',
      );
      final int end = page.indexOf('Future<void> _saveScreenshot(', idx);
      expect(
        end,
        greaterThan(idx),
        reason: '_toggleClipExport 应位于截图 helper 之前，便于同组维护',
      );
      final String body = page.substring(idx, end);

      // 7eba730dbf 起互联远端改走 host 原料段 + 本机烧字幕，可以导出；门控收成
      // 「拿不到片段源键 = 没有可裁的源」：本地返回本机路径，互联远端返回
      // host 条目键，其它远端（媒体服务器 / 在线源 / 直链）返回 null 并提示先下载。
      final String keyBody = _methodBody(
        page,
        'String? _clipExportSourceKey()',
      );
      expect(
        keyBody.contains('if (!_isRemote) return _currentVideoPath;'),
        isTrue,
        reason: '本地视频的源键就是本机路径',
      );
      expect(
        keyBody.contains('if (target == null) return null;'),
        isTrue,
        reason: '非互联远端没有 host 端裁切，源键必须是 null',
      );

      final int keyRead = body.indexOf(
        'final String? sourceKey = _clipExportSourceKey();',
      );
      final int remoteCheck = body.indexOf('if (sourceKey == null)');
      final int remoteMessage = body.indexOf(
        't.video_clip_export_remote_download_required',
      );
      final int markingWrite = body.indexOf('_clipExportMarking = true');
      final int exportingWrite = body.indexOf('_clipExporting = true');

      expect(keyRead, greaterThanOrEqualTo(0), reason: '门控必须基于片段源键');
      expect(remoteCheck, greaterThan(keyRead), reason: '没有可裁源的远端视频必须先门控');
      expect(
        remoteMessage,
        greaterThan(remoteCheck),
        reason: '远端路径必须给出“先下载到本机”提示',
      );
      expect(
        markingWrite,
        greaterThan(remoteMessage),
        reason: '远端提示必须早于进入 marking 状态',
      );
      expect(
        exportingWrite,
        greaterThan(remoteMessage),
        reason: '远端提示必须早于进入 exporting 状态',
      );
    });

    test('切源会在 ffmpeg 启动前取消片段导出状态', () {
      final int idx = page.indexOf('Future<void> _toggleClipExport(');
      expect(idx, greaterThanOrEqualTo(0));
      final int end = page.indexOf('Future<void> _saveScreenshot(', idx);
      // 折掉换行/缩进后比对，免得 dart format 的换行位置成为守卫的隐形前提。
      final String body = page
          .substring(idx, end)
          .replaceAll(RegExp(r'\s+'), ' ');

      final int outputPathAwait = body.indexOf(
        'final String? outputPath = await _resolveClipOutputPath',
      );
      // 源比对用片段源键（本地 = 路径，互联远端 = host 条目键），见 7eba730dbf。
      final int preStartGuard = body.indexOf(
        'generation != _clipExportGeneration || '
        '_clipExportSourceKey() != startPath',
        outputPathAwait,
      );
      final int exportingWrite = body.indexOf(
        '_clipExporting = true',
        outputPathAwait,
      );
      final int remoteExportCall = body.indexOf(
        'await _exportRemoteClipFile(',
        outputPathAwait,
      );
      final int localExportCall = body.indexOf(
        'await _exportClipFile(',
        outputPathAwait,
      );

      expect(outputPathAwait, greaterThanOrEqualTo(0));
      expect(preStartGuard, greaterThan(outputPathAwait));
      expect(preStartGuard, lessThan(exportingWrite));
      expect(remoteExportCall, greaterThan(preStartGuard));
      expect(localExportCall, greaterThan(preStartGuard));
    });

    test('页面文案保持源片段导出语义', () {
      final int idx = page.indexOf('Future<void> _toggleClipExport(');
      expect(idx, greaterThanOrEqualTo(0));
      final int end = page.indexOf('Future<void> _saveScreenshot(', idx);
      final String body = page.substring(idx, end);
      final String formerPixelCaptureTerm = String.fromCharCodes(<int>[
        0x5f55,
        0x5c4f,
      ]);
      final String formerEnglishTerm = <String>[
        'screen',
        'recording',
      ].join(' ');
      expect(body.contains(formerPixelCaptureTerm), isFalse);
      expect(body.contains(formerEnglishTerm), isFalse);
    });
  });
}
