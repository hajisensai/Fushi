import 'dart:io';

import 'package:test/test.dart';

/// BUG-4943 守卫（反馈 OU6bZvpCd0：小米 32 位低端机后台 ANR，主线程 state=D 停在
/// `libc fsync ← libflutter ← libapp`）。
///
/// 诊断标记（会话标记、活动 / 查词 / 导入 / 启动步进面包屑、致命错误同步追加）都在 UI
/// isolate 上同步写；Flutter 3.29 起 Android 的 UI isolate 就是平台主线程。它们要防的是
/// 「进程下一刻没了」，`write` 进内核页缓存就够（进程死不丢页缓存），fsync 只多防整机掉电，
/// 却在 IO 拥塞时把主线程卡几秒。本守卫钉住：这些方法**仍然同步写**（崩前的语义不变），
/// 但**不 fsync**（不带 `flush: true`、不调 `flushSync`）。
void main() {
  String libFile(String relative) =>
      File(relative).readAsStringSync().replaceAll('\r\n', '\n');

  /// 按 [signature]（以起始 `(` 结尾）截出函数体：先配平参数列表圆括号，再从其后第一个
  /// `{` 起配平大括号。
  String fnBody(String src, String signature) {
    final int start = src.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: '函数 $signature 必须存在。');
    int i = start + signature.length - 1;
    expect(src[i], '(', reason: 'signature 必须以 "(" 结尾。');
    int paren = 0;
    for (; i < src.length; i++) {
      if (src[i] == '(') paren++;
      if (src[i] == ')') {
        paren--;
        if (paren == 0) break;
      }
    }
    final int bodyStart = src.indexOf('{', i);
    int depth = 0;
    for (int j = bodyStart; j < src.length; j++) {
      if (src[j] == '{') depth++;
      if (src[j] == '}') {
        depth--;
        if (depth == 0) return src.substring(bodyStart, j + 1);
      }
    }
    fail('函数 $signature 的大括号没配平。');
  }

  const Map<String, List<String>> markerWriters = <String, List<String>>{
    'lib/src/diagnostics/previous_exit_log.dart': <String>[
      // SessionMarker：每 30 秒内存采样、每次生命周期 / 内存压力都调。
      '  void _write(',
      // ActivityBreadcrumb：查词弹窗、复习同步各阶段、ASR 内存闸都调。
      '  static void mark(',
    ],
    'lib/src/utils/misc/error_log_service.dart': <String>[
      '  void markImportStart(',
      '  void markLookupStackDepth(',
      '  void markInitStep(',
      '  void logFatal(',
      '  void _trimLogFileToMaxBytesSync(',
    ],
  };

  for (final MapEntry<String, List<String>> file in markerWriters.entries) {
    for (final String signature in file.value) {
      test('${file.key} ${signature.trim()} 同步写但不在主线程 fsync', () {
        final String body = fnBody(libFile(file.key), signature);
        expect(
          body,
          contains('writeAsStringSync('),
          reason: '诊断标记必须同步写进页缓存，进程下一刻被杀也要留得下。',
        );
        expect(
          body,
          isNot(contains('flush: true')),
          reason:
              'UI isolate 即 Android 主线程，同步 fsync 会在 IO 拥塞时卡成 ANR（BUG-4943）。',
        );
        expect(body, isNot(contains('flushSync(')));
      });
    }
  }
}
