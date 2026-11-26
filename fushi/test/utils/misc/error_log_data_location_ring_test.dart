import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_diagnostics.dart';
import 'package:fushi/src/storage/app_paths.dart' show dataRootsDiagnostic;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// BUG-5490：数据位置诊断（书库根判定 / 沙箱重定位 / 散书合并 / 迁移被拒 / 词典文件
/// 缺失）进独立的持久环：跨运行保留、不被普通诊断挤掉、不随清空日志消失、固定上限，
/// 反馈日志里排在最末尾。
void main() {
  late Directory tmp;
  final ErrorLogService svc = ErrorLogService.instance;

  Future<void> restart() async {
    await svc.pendingFileWrite;
    await svc.init(directoryOverride: tmp);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('errlog_data_location_test');
    await svc.init(directoryOverride: tmp);
    await svc.clear();
  });

  tearDown(() async {
    await svc.pendingFileWrite;
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上偶发占用：临时目录残留不影响断言。
    }
  });

  test('跨运行保留：重新 init 后还在，且不计入用户可见错误', () async {
    svc.logDataLocation('AppModel.sandboxRelocation', 'rebased 12 rows');
    expect(svc.entries, isEmpty);
    await restart();
    expect(svc.dataLocationEntries.map((ErrorLogEntry e) => e.error), <String>[
      'rebased 12 rows',
    ]);
    expect(svc.dataLocationEntries.single.source, 'AppModel.sandboxRelocation');
  });

  test('普通诊断刷屏挤不掉它；清空日志也不清它', () async {
    svc.logDataLocation('AppPaths.androidLocation', 'external → internal');
    for (int i = 0; i < 300; i++) {
      svc.logDiagnostic('UpdateChecker.httpGet', 'timeout $i');
    }
    await svc.clear();
    expect(svc.dataLocationEntries, hasLength(1));
    await restart();
    expect(svc.dataLocationEntries.single.error, 'external → internal');
    expect(svc.getFullLog(), contains('external → internal'));
  });

  test('条数与字节都有上限，丢的是最旧的', () async {
    for (int i = 0; i < ErrorLogService.maxDataLocationEntries + 25; i++) {
      svc.logDataLocation('AppModel.dataRoots', 'entry $i');
    }
    expect(
      svc.dataLocationEntries,
      hasLength(ErrorLogService.maxDataLocationEntries),
    );
    expect(svc.dataLocationEntries.last.error, 'entry 84');
    expect(svc.dataLocationEntries.first.error, 'entry 25');

    final String huge = 'x' * 50000;
    for (int i = 0; i < 40; i++) {
      svc.logDataLocation('AppModel.sandboxRelocation', '$i $huge');
    }
    for (final ErrorLogEntry e in svc.dataLocationEntries) {
      expect(
        e.error.length,
        lessThanOrEqualTo(ErrorLogService.maxDataLocationEntryChars + 20),
      );
    }
    await svc.pendingFileWrite;
    final File file = File('${tmp.path}/data_location_log.jsonl');
    expect(
      await file.length(),
      lessThanOrEqualTo(ErrorLogService.maxDataLocationFileBytes),
    );
  });

  test('IfChanged：同一来源正文没变不占条目，变了才记', () {
    final String a = dataRootsDiagnostic(
      libraryRoot: '/data/a',
      supportRoot: '/data/s',
      androidLocation: 'external',
    );
    expect(svc.logDataLocationIfChanged('AppModel.dataRoots', a), isTrue);
    expect(svc.logDataLocationIfChanged('AppModel.dataRoots', a), isFalse);
    // 别的来源插进来不影响「同来源最近一条」的比较。
    svc.logDataLocation('AppModel.sandboxRelocation', 'noop');
    expect(svc.logDataLocationIfChanged('AppModel.dataRoots', a), isFalse);
    final String b = dataRootsDiagnostic(
      libraryRoot: '/data/b',
      supportRoot: '/data/s',
      androidLocation: 'internal',
    );
    expect(svc.logDataLocationIfChanged('AppModel.dataRoots', b), isTrue);
    expect(svc.dataLocationEntries, hasLength(3));
  });

  test('坏行逐行跳过，不让一行坏掉整份取证', () async {
    svc.logDataLocation('AppModel.dataRoots', 'good one');
    await svc.pendingFileWrite;
    final File file = File('${tmp.path}/data_location_log.jsonl');
    await file.writeAsString(
      '{not json\n${await file.readAsString()}["array"]\n',
    );
    await restart();
    expect(svc.dataLocationEntries.map((ErrorLogEntry e) => e.error), <String>[
      'good one',
    ]);
  });

  test('反馈日志：数据位置段排在最末尾（尾部截断时最后才丢），且只出现一次', () {
    svc.log('Reader.parse', 'FormatException: bad epub');
    svc.logDiagnostic('UpdateChecker.httpGet', 'timeout');
    svc.logDataLocation('AppPaths.androidLocation', 'MARK-DATA-LOCATION');
    final String text = collectFeedbackLogText(includeDebugLog: false);
    final int section = text.indexOf('==== data location diagnostics ====');
    expect(section, greaterThan(text.indexOf('FormatException')));
    expect(section, greaterThan(text.indexOf('timeout')));
    expect(text.indexOf('MARK-DATA-LOCATION'), greaterThan(section));
    expect('MARK-DATA-LOCATION'.allMatches(text), hasLength(1));
  });

  test('源码守卫：数据位置类来源都写进持久环，不再写只在内存的诊断段', () {
    final Map<String, List<String>> sources = <String, List<String>>{
      'lib/src/models/app_model.dart': <String>[
        'AppPaths.androidLocation',
        'AppPaths.androidStrayLibrary',
        'AppModel.sandboxRelocation',
        'AppModel.dataRoots',
        'AppModel.dictionaryFiles',
      ],
      'lib/src/sync/sync_settings_schema/data_root.part.dart': <String>[
        'DataRootMigration.androidClearStaleTarget',
      ],
    };
    for (final MapEntry<String, List<String>> file in sources.entries) {
      final String src = File(file.key).readAsStringSync();
      for (final String source in file.value) {
        // 直接写字面量，或先落成 `const String source = '<来源>'` 再传 `source`。
        final String quoted = RegExp.escape("'$source'");
        final bool direct = RegExp(
          'logDataLocation(IfChanged)?\\(\\s*$quoted',
        ).hasMatch(src);
        final bool viaConst =
            RegExp('const String source = $quoted').hasMatch(src) &&
            RegExp('logDataLocation(IfChanged)?\\(\\s*source,').hasMatch(src);
        expect(
          direct || viaConst,
          isTrue,
          reason: '${file.key}: $source 应走 logDataLocation',
        );
        expect(
          RegExp(
            "logDiagnostic\\(\\s*'${RegExp.escape(source)}'",
          ).hasMatch(src),
          isFalse,
          reason: '${file.key}: $source 不该再走 logDiagnostic',
        );
      }
    }
  });

  group('BUG-5492：数据位置环挪到内部 support 根', () {
    test('旧位置（诊断目录）的环搬到新位置并删旧文件', () async {
      final File legacy = File('${tmp.path}/old/data_location_log.jsonl')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"a":1}\n');
      final File target = File('${tmp.path}/new/data_location_log.jsonl');
      await ErrorLogService.adoptLegacyDataLocationLog(
        legacy: legacy,
        target: target,
      );
      expect(target.readAsStringSync(), '{"a":1}\n');
      expect(legacy.existsSync(), isFalse);
    });

    test('新位置已有环时不覆盖、不删旧文件', () async {
      final File legacy = File('${tmp.path}/old/data_location_log.jsonl')
        ..createSync(recursive: true)
        ..writeAsStringSync('old');
      final File target = File('${tmp.path}/new/data_location_log.jsonl')
        ..createSync(recursive: true)
        ..writeAsStringSync('new');
      await ErrorLogService.adoptLegacyDataLocationLog(
        legacy: legacy,
        target: target,
      );
      expect(target.readAsStringSync(), 'new');
      expect(legacy.existsSync(), isTrue);
    });

    test('新旧同一文件（桌面 / 测试目录）什么都不做', () async {
      final File same = File('${tmp.path}/data_location_log.jsonl')
        ..writeAsStringSync('keep');
      await ErrorLogService.adoptLegacyDataLocationLog(
        legacy: same,
        target: same,
      );
      expect(same.readAsStringSync(), 'keep');
    });
  });
}
