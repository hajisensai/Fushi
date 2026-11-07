import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/native_attribution_probe.dart';

void main() {
  tearDown(resetNativeAttributionProbe);

  group('线程 stat 解析', () {
    test('线程名带空格与括号：以最后一个 ) 为界，utime+stime 相加', () {
      const String stat =
          '4321 (fushi (rwkv) 3) R 1 2 3 4 5 6 7 8 9 10 150 25 0 0 20 0 1 0';
      final ProcThreadStat? s = parseProcThreadStat(stat);
      expect(s, isNotNull);
      expect(s!.name, 'fushi (rwkv) 3');
      expect(s.state, 'R');
      expect(s.ticks, 175);
    });

    test('字段不够返回 null', () {
      expect(parseProcThreadStat('12 (x) S 1 2'), isNull);
      expect(parseProcThreadStat('garbage'), isNull);
    });
  });

  test('CPU 增量按线程组归并、数字折成 #，按增量排序，新线程按全部累计算', () {
    const ProcThreadStat w0 = ProcThreadStat(
      name: 'DartWorker',
      state: 'S',
      ticks: 100,
    );
    final String? out = describeThreadCpuDelta(
      <int, ProcThreadStat>{
        1: w0,
        2: const ProcThreadStat(name: 'fushi-rwkv-0', state: 'S', ticks: 10),
        3: const ProcThreadStat(name: '1.ui', state: 'S', ticks: 50),
      },
      <int, ProcThreadStat>{
        1: const ProcThreadStat(name: 'DartWorker', state: 'S', ticks: 130),
        2: const ProcThreadStat(name: 'fushi-rwkv-0', state: 'R', ticks: 1010),
        4: const ProcThreadStat(name: 'fushi-rwkv-1', state: 'R', ticks: 900),
        3: const ProcThreadStat(name: '1.ui', state: 'S', ticks: 50),
      },
    );
    expect(out, 'cpu=19.3s[fushi-rwkv-#×2 19.0s R2; DartWorker 0.3s]');
  });

  test('线程名归组', () {
    expect(threadGroupOf('fushi-rwkv-12'), 'fushi-rwkv-#');
    expect(threadGroupOf('DartWorker'), 'DartWorker');
  });

  group('maps 分组', () {
    test('匿名映射按名字归组，文件映射不计，secondary 列块大小分布', () {
      const String maps = '''
7000000000-7000100000 rw-p 00000000 00:00 0                              [anon:scudo:secondary]
7000200000-7000300000 rw-p 00000000 00:00 0                              [anon:scudo:secondary]
7000400000-7000c00000 rw-p 00000000 00:00 0                              [anon:scudo:secondary]
7100000000-7110000000 rw-p 00000000 00:00 0                              [anon:scudo:primary]
7200000000-7200400000 rw-p 00000000 00:00 0                              [anon:dart-oldspace]
7300000000-7300001000 r-xp 00000000 fd:01 1234                           /system/lib64/libc.so
7400000000-7400010000 rw-p 00000000 00:00 0
ffffffffff600000-ffffffffff601000 r-xp 00000000 00:00 0                  [vsyscall]
''';
      expect(
        describeMaps(maps),
        'vm=[scudo:primary 256MB/1; scudo:secondary 10.0MB/3; '
        'dart-oldspace 4.0MB/1; anon 64KB/1] sec=[8.0MB×1 1.0MB×2]',
      );
    });

    test('名字里的数字 / 十六进制串折掉，空正文返回 null', () {
      expect(
        mappingGroupOf('[anon:stack_and_tls:12345]', inode: 0),
        'stack_and_tls:#',
      );
      expect(mappingGroupOf('/data/app/x.so', inode: 9), isNull);
      expect(describeMaps(''), isNull);
    });
  });

  test('smaps 按映射组累计 Rss，文件映射按文件名', () {
    const String smaps = '''
7000000000-7000100000 rw-p 00000000 00:00 0                              [anon:scudo:secondary]
Size:               1024 kB
Rss:                1024 kB
7000200000-7000300000 rw-p 00000000 00:00 0                              [anon:scudo:secondary]
Rss:                 512 kB
7300000000-7300100000 r--s 00000000 fd:01 99                             /data/user/0/app/srs.db
Rss:                2048 kB
''';
    expect(describeSmapsRss(smaps), 'srs.db 2.0MB; scudo:secondary 1.5MB');
  });
}
