// Windows 专属：两个写者在同一瞬间 rename 到同一个目标时，`MoveFileEx` 会让其中
// 一个以「拒绝访问」失败（POSIX 没有这个限制）。`writeTextFileAtomically` 在
// Windows 上让同一目标的替换互斥（系统临时目录里一个锁文件上的字节区间锁，
// BUG-4801）。各平台共有的「全部写者成功」在 atomic_text_file_concurrent_test.dart；
// 这里钉 Windows 这一侧自己的事：互斥不往目标目录里放东西、锁文件不长大、
// 出错的写者不把锁带走、一个目标卡住不耽误别的目标。
@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi_engine/utils/misc/atomic_text_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

File _lockFile() =>
    File(p.join(Directory.systemTemp.path, kAtomicWriteReplaceLockFileName));

void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('atomic_text_file_win_');
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('同 isolate 12 个写者并发写同一个目标：全部成功，目标目录里只有目标本身', () async {
    final File target = File(p.join(temporary.path, 'page.json'));
    final List<String> contents = <String>[
      for (int i = 0; i < 12; i++) jsonEncode(List<int>.filled(200000, i)),
    ];
    // 不加互斥时这里必有写者以「拒绝访问」（errno 5）失败。
    for (int round = 0; round < 5; round++) {
      await Future.wait(<Future<void>>[
        for (final String content in contents)
          writeTextFileAtomically(target, content),
      ]);
      expect(contents, contains(target.readAsStringSync()));
    }
    expect(
      <String>[
        for (final FileSystemEntity entry in temporary.listSync())
          p.basename(entry.path),
      ],
      <String>['page.json'],
      reason: '不留临时文件，也不在目标旁边放锁文件',
    );
  });

  test('跨 isolate 并发写同一个目标，同时各自还在写别的目标：全部成功', () async {
    final String shared = p.join(temporary.path, 'shared.json');
    final String dir = temporary.path;
    Future<void> writer(int seed) => Isolate.run<void>(() async {
      for (int i = 0; i < 60; i++) {
        await Future.wait(<Future<void>>[
          writeTextFileAtomically(
            File(shared),
            jsonEncode(List<int>.filled(4000, seed)),
          ),
          writeTextFileAtomically(
            File(p.join(dir, 'own-$seed.json')),
            jsonEncode(<int>[seed, i]),
          ),
        ]);
      }
    });

    await Future.wait(<Future<void>>[
      for (int seed = 1; seed <= 4; seed++) writer(seed),
    ]);
    final Object? decoded = jsonDecode(File(shared).readAsStringSync());
    expect((decoded! as List<Object?>).length, 4000);
    for (int seed = 1; seed <= 4; seed++) {
      expect(
        jsonDecode(File(p.join(dir, 'own-$seed.json')).readAsStringSync()),
        <int>[seed, 59],
      );
    }
    expect(temporary.listSync(), hasLength(5));
  });

  test('锁文件在系统临时目录、始终 0 字节；替换失败的写者不把锁带走', () async {
    final File target = File(p.join(temporary.path, 'page.json'));
    await writeTextFileAtomically(target, 'first');
    expect(_lockFile().existsSync(), isTrue);
    expect(_lockFile().lengthSync(), 0);
    expect(p.equals(_lockFile().parent.path, temporary.path), isFalse);

    // 目标位置是个目录：替换失败。同一个目标字节上的锁必须已经放掉，把目录
    // 挪走之后再写同一路径不会卡住。
    final Directory blocked = Directory(p.join(temporary.path, 'blocked.json'))
      ..createSync();
    await expectLater(
      writeTextFileAtomically(File(blocked.path), 'x'),
      throwsA(isA<FileSystemException>()),
    );
    blocked.deleteSync();
    await writeTextFileAtomically(
      File(blocked.path),
      'second',
    ).timeout(const Duration(seconds: 10));
    expect(File(blocked.path).readAsStringSync(), 'second');
    expect(_lockFile().lengthSync(), 0);
  });

  // 别的进程 / isolate 拿着某个目标的锁不放（这里用另一个句柄直接锁住它的字节
  // 来模拟，比如网络盘上的 rename 迟迟不返回）：本 isolate 写别的目标不受影响。
  test('一个目标的替换被别人的锁卡住：别的目标照常写完，放锁后被卡的也写完', () async {
    final File stuck = File(p.join(temporary.path, 'stuck.json'));
    final File other = File(p.join(temporary.path, 'other.json'));
    final int offset = replaceLockOffsetForTarget(stuck);
    expect(replaceLockOffsetForTarget(other), isNot(offset));
    final RandomAccessFile holder = await _lockFile().open(
      mode: FileMode.append,
    );
    bool stuckDone = false;
    late final Future<void> stuckWrite;
    try {
      await holder.lock(FileLock.blockingExclusive, offset, offset + 1);
      stuckWrite = writeTextFileAtomically(
        stuck,
        'late',
      ).then((_) => stuckDone = true);
      await writeTextFileAtomically(
        other,
        'on time',
      ).timeout(const Duration(seconds: 10));
      expect(other.readAsStringSync(), 'on time');
      expect(await readAtomicallyWrittenTextFile(other), 'on time');
      expect(stuckDone, isFalse, reason: '锁还被别人拿着');
      expect(stuck.existsSync(), isFalse);
    } finally {
      await holder.unlock(offset, offset + 1);
      await holder.close();
    }
    await stuckWrite.timeout(const Duration(seconds: 10));
    expect(stuck.readAsStringSync(), 'late');
  });

  // 同时卡住的目标比名额多：没拿到名额的在 Dart 里等，不去占 IO 服务口；放锁
  // 之后全部写完。
  test('被卡住的目标多于并发名额：放锁后全部写完', () async {
    const int targets = kAtomicWriteMaxConcurrentLockSections + 4;
    final List<File> files = <File>[
      for (int i = 0; i < targets; i++)
        File(p.join(temporary.path, 'stuck-$i.json')),
    ];
    final RandomAccessFile holder = await _lockFile().open(
      mode: FileMode.append,
    );
    final List<int> offsets = <int>[
      for (final File file in files) replaceLockOffsetForTarget(file),
    ];
    expect(offsets.toSet(), hasLength(targets));
    int done = 0;
    late final List<Future<void>> writes;
    try {
      for (final int offset in offsets) {
        await holder.lock(FileLock.blockingExclusive, offset, offset + 1);
      }
      writes = <Future<void>>[
        for (final File file in files)
          writeTextFileAtomically(file, p.basename(file.path)).then((_) {
            done += 1;
          }),
      ];
      // 名额全被卡住的写者占着时，IO 服务口仍有空：别的文件操作照常。
      final File plain = File(p.join(temporary.path, 'plain.txt'));
      await plain.writeAsString('x').timeout(const Duration(seconds: 10));
      expect(await plain.readAsString(), 'x');
      expect(done, 0);
    } finally {
      for (final int offset in offsets) {
        await holder.unlock(offset, offset + 1);
      }
      await holder.close();
    }
    await Future.wait(writes).timeout(const Duration(seconds: 20));
    for (final File file in files) {
      expect(file.readAsStringSync(), p.basename(file.path));
    }
  });

  test('锁文件被清理工具删掉：下一次写入照常', () async {
    final File target = File(p.join(temporary.path, 'page.json'));
    await writeTextFileAtomically(target, 'first');
    // 没有写入在进行时锁文件没人打开着，删得掉；测试并行跑时别的 isolate 可能
    // 正好拿着它，那就删不掉——两种情况下一次写入都得成功。
    try {
      _lockFile().deleteSync();
    } on FileSystemException {
      // 别的测试 isolate 正拿着：等价于「没被删」。
    }
    await writeTextFileAtomically(target, 'second');
    expect(target.readAsStringSync(), 'second');
  });
}
