import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-911 守卫：fail-open 的 catch 静默吞异常致线上不可诊断。
///
/// 这批修复**不改 fail-open 语义**（继续吞 / 继续降级 / 继续返回空 / 继续 fire-and-forget），
/// 只在原本静默的 catch / 未捕获的 DB 写路径补 ErrorLogService.log（用户可见错误、计数落盘）
/// 或 ErrorLogService.logDiagnostic（预期网络失败、不计数）。
///
/// 本守卫用**方法体切片**（按方法名锚点，不用裸行号）钉住每个补日志点仍在其对应方法体内，
/// 未来有人把日志删掉会变红。
void main() {
  String libFile(String relative) =>
      File(relative).readAsStringSync().replaceAll('\r\n', '\n');

  /// 按 [signature]（以起始 `(` 结尾，如 `_flush(`）截出函数体：先配平参数列表的圆括号
  /// （命名参数的 `{...}` 不能当函数体大括号），再从参数列表后的第一个 `{` 起配平大括号。
  String fnBody(String src, String signature) {
    final int start = src.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0),
        reason: '函数 $signature 必须存在（结构守卫锚点）。');
    int i = start + signature.length - 1; // 指向起始 '('
    expect(src[i], '(', reason: 'signature 必须以 "(" 结尾。');
    int paren = 0;
    for (; i < src.length; i++) {
      final String ch = src[i];
      if (ch == '(') paren++;
      if (ch == ')') {
        paren--;
        if (paren == 0) break;
      }
    }
    final int bodyStart = src.indexOf('{', i);
    expect(bodyStart, greaterThanOrEqualTo(0),
        reason: '函数 $signature 参数列表后必须有函数体 "{"。');
    int depth = 0;
    for (i = bodyStart; i < src.length; i++) {
      final String ch = src[i];
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) return src.substring(bodyStart, i + 1);
      }
    }
    fail('函数 $signature 大括号不配平，无法截出函数体。');
  }

  // 容忍 dart format 把 ErrorLogService.instance.log( 折行成
  // ErrorLogService.instance 换行后 .log(，用正则匹配中间任意空白。
  final RegExp logRe = RegExp(r'ErrorLogService\.instance\s*\.log\(');
  final RegExp diagRe =
      RegExp(r'ErrorLogService\.instance\s*\.logDiagnostic\(');

  group('collection_exporter.saveOrShareExport fail-open 补 log', () {
    test('catch 仍走 notify 且补 ErrorLogService.log', () {
      final String src = libFile('lib/src/utils/misc/collection_exporter.dart');
      final String body = fnBody(src, 'Future<void> saveOrShareExport(');
      expect(body, contains('collectionExport.saveOrShareExport'),
          reason:
              'saveOrShareExport 的 catch 必须补 ErrorLogService.log（source tag）。');
      expect(logRe.hasMatch(body), isTrue,
          reason: 'saveOrShareExport 方法体内必须有 ErrorLogService.instance.log 调用。');
      // fail-open 未变：仍向用户提示导出失败。
      expect(body, contains('notify(t.collection_export_failed)'),
          reason: 'fail-open 语义未变：catch 仍 notify 用户导出失败。');
    });
  });

  group('jimaku_client 预期网络失败路径补 logDiagnostic', () {
    late String src;
    setUpAll(() => src = libFile('lib/src/media/video/jimaku_client.dart'));

    test('_searchEntries catch 补 diagnostic 且仍返回空列表', () {
      final String body =
          fnBody(src, 'Future<List<JimakuEntry>> _searchEntries(');
      expect(body, contains('JimakuClient.searchEntries'));
      expect(diagRe.hasMatch(body), isTrue);
      expect(body, contains('return const <JimakuEntry>[];'),
          reason: 'fail-open 未变：仍返回空列表。');
    });

    test('listFiles catch 补 diagnostic 且仍返回空列表', () {
      final String body = fnBody(src, 'Future<List<JimakuFile>> listFiles(');
      expect(body, contains('JimakuClient.listFiles'));
      expect(diagRe.hasMatch(body), isTrue);
      expect(body, contains('return const <JimakuFile>[];'),
          reason: 'fail-open 未变：仍返回空列表。');
    });

    test('downloadFile catch 补 diagnostic 且仍返回 null', () {
      final String body = fnBody(src, 'Future<Uint8List?> downloadFile(');
      expect(body, contains('JimakuClient.downloadFile'));
      expect(diagRe.hasMatch(body), isTrue);
      expect(body, contains('return null;'), reason: 'fail-open 未变：仍返回 null。');
    });

    test('纯解析兜底也补 diagnostic', () {
      expect(src, contains('JimakuClient.parseJimakuEntries'));
      expect(src, contains('JimakuClient.parseJimakuFiles'));
    });
  });

  // v92：观看时长的 DB 写挪进 StudyClock（`_flush` 已删），VideoWatchTracker 剩下的
  // 唯一 DB 写路径是完成标记 `_checkCompletion`（每 tick + stop 各查一次）。
  group('video_watch_tracker._checkCompletion fire-and-forget 补 log', () {
    test('_checkCompletion 的 DB 写包 try/catch 并补 ErrorLogService.log', () {
      final String src =
          libFile('lib/src/media/video/video_watch_tracker.dart');
      final String body = fnBody(src, 'Future<void> _checkCompletion(');
      expect(body, contains('VideoWatchTracker.checkCompletion'),
          reason:
              '_checkCompletion 的 DB 写异常必须补 ErrorLogService.log（source tag）。');
      expect(logRe.hasMatch(body), isTrue,
          reason: '_checkCompletion 方法体内必须有 ErrorLogService.instance.log 调用。');
      // fail-open 未变：周期 tick 仍是 unawaited fire-and-forget（异常不冒泡阻塞播放）。
      expect(src, contains('unawaited(_checkCompletion())'),
          reason: 'fail-open 未变：周期 tick 仍 fire-and-forget。');
    });
  });

  group('reader navigation 阅读统计 / 位置落盘补 log', () {
    late String src;
    setUpAll(() => src = libFile(
        'lib/src/pages/implementations/reader_fushi/navigation.part.dart'));

    test('_flushReadingStats 只委托 StudyClock；时钟写链 fail-open 保持 dirty 并 debugPrint',
        () {
      // v92：阅读统计的 DB 写挪进 fushi_audio 的 StudyClock（页面侧没有 try/catch 可
      // 补日志了）。fail-open 语义现在由时钟写链承担：写失败不冒泡、段留 dirty、
      // 下个 tick 用绝对值重写。fushi_audio 不依赖 ErrorLogService，只能 debugPrint。
      final String body = fnBody(src, 'Future<void> _flushReadingStats(');
      expect(body, contains('_studyClock?.flushNow()'),
          reason: '_flushReadingStats 只能是结算时钟，不得再自己写库。');
      final String clock = libFile(
          '../packages/fushi_audio/lib/src/audiobook/study_clock.dart');
      final String enqueue = fnBody(clock, 'void _enqueueWrite(');
      expect(enqueue, contains('catchError('),
          reason: 'StudyClock 写链必须捕获写失败（fail-open：不阻塞阅读 / 播放）。');
      expect(enqueue, contains('seg.dirty = true'),
          reason: '写失败保持 dirty，下个 tick 用绝对值重写。');
      expect(enqueue, contains("debugPrint('[study-clock] write error"),
          reason: 'fail-open 未变：保留 debugPrint 诊断。');
    });

    test('_persistPosition 的 repo.save 包 catch 并补 ErrorLogService.log', () {
      final String body = fnBody(src, 'Future<void> _persistPosition(');
      expect(body, contains('ReaderFushi._persistPosition'));
      expect(logRe.hasMatch(body), isTrue);
    });
  });
}
