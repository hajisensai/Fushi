import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_log.dart';

void main() {
  late Directory dir;
  late File log;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('glog_test');
    log = File('${dir.path}${Platform.pathSeparator}hibiki_glookup.log');
    debugSetGlookupLogFile(log);
  });

  tearDown(() {
    debugSetGlookupLogFile(null);
    dir.deleteSync(recursive: true);
  });

  test('逐行追加，不覆盖其它写者已追加的内容', () {
    glog('first');
    // 模拟 runner 的 NativeGlog 在两行之间追加。
    log.writeAsStringSync('native line\n', mode: FileMode.append);
    glog('second');

    final List<String> lines = log.readAsLinesSync();
    expect(lines, hasLength(3));
    expect(lines[0], endsWith('  first'));
    expect(lines[1], 'native line');
    expect(lines[2], endsWith('  second'));
  });

  test('超长行截断并注明截掉的字符数', () {
    final String long = 'x' * (kGlookupLogMaxLineChars + 25);
    expect(clampGlookupLogLine('short'), 'short');
    expect(
      clampGlookupLogLine(long),
      '${'x' * kGlookupLogMaxLineChars}…(+25 chars)',
    );
    glog(long);
    expect(log.readAsStringSync(), contains('…(+25 chars)'));
  });

  test('超过上限的旧日志整体换名为 .1，新内容写进新文件', () {
    final RandomAccessFile raf = log.openSync(mode: FileMode.write);
    raf.truncateSync(kGlookupLogMaxBytes + 1);
    raf.closeSync();
    final File stale = File('${log.path}.1')..writeAsStringSync('stale');

    glog('after rotate');

    final File previous = File('${log.path}.1');
    expect(previous.lengthSync(), kGlookupLogMaxBytes + 1);
    expect(stale.path, previous.path);
    expect(log.readAsLinesSync().single, endsWith('  after rotate'));
  });
}
