import 'dart:convert';
import 'dart:io';

import 'package:fushi/src/media/manga/mihon/mihon_sidecar_temp_dir.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../helpers/source_guard.dart';

/// BUG-5046：桌面 Mihon sidecar 的 `java.io.tmpdir` 由宿主持有。修前 JVM 用系统临时
/// 目录：NanoHTTPD 每个请求体一个删不掉的 `NanoHTTPD-*` 文件、强杀后的
/// `mextensionserver*` 扩展 jar 目录，都永不回收（本机实测 5 周 504 个 / 40 MB）。
void main() {
  late Directory data;

  setUp(() async {
    data = await Directory.systemTemp.createTemp('mihon-sidecar-tmp-');
  });
  tearDown(() async {
    if (data.existsSync()) await data.delete(recursive: true);
  });

  Directory root() => MihonSidecarTempDir.rootOf(data);

  test('每个 JVM 一个数据目录下的独占目录，释放后连锁文件一起删掉', () async {
    final MihonSidecarTempDir tmp = await MihonSidecarTempDir.create(data);
    expect(p.isWithin(root().path, tmp.directory.path), isTrue);
    expect(tmp.directory.existsSync(), isTrue);
    File(
      p.join(tmp.directory.path, 'NanoHTTPD-1'),
    ).writeAsBytesSync(<int>[1, 2, 3]);
    Directory(
      p.join(tmp.directory.path, 'mextensionserver42'),
    ).createSync(recursive: true);

    await tmp.release();

    expect(root().listSync(), isEmpty);
  });

  test('持有者已不在的旧目录（锁能锁上 / 没有锁文件）在下一次起 JVM 时清掉', () async {
    final Directory stale = Directory(p.join(root().path, 'jvm-1-1-1'))
      ..createSync(recursive: true);
    File(p.join(stale.path, 'NanoHTTPD-9')).writeAsBytesSync(<int>[0]);
    File(p.join(root().path, 'jvm-1-1-1.lock')).writeAsStringSync('');
    final Directory orphan = Directory(p.join(root().path, 'jvm-2-2-2'))
      ..createSync();
    File(p.join(orphan.path, 'extension.jar')).writeAsBytesSync(<int>[0]);
    File(p.join(root().path, 'jvm-3-3-3.lock')).writeAsStringSync('');
    // 不是本类建的东西不碰。
    final File foreign = File(p.join(root().path, 'keep.txt'))
      ..writeAsStringSync('x');

    final MihonSidecarTempDir tmp = await MihonSidecarTempDir.create(data);
    addTearDown(tmp.release);

    expect(stale.existsSync(), isFalse);
    expect(File(p.join(root().path, 'jvm-1-1-1.lock')).existsSync(), isFalse);
    expect(orphan.existsSync(), isFalse);
    expect(File(p.join(root().path, 'jvm-3-3-3.lock')).existsSync(), isFalse);
    expect(foreign.existsSync(), isTrue);
    expect(tmp.directory.existsSync(), isTrue);
  });

  test('本进程另一个还活着的 JVM 目录不会被清扫', () async {
    final MihonSidecarTempDir first = await MihonSidecarTempDir.create(data);
    final MihonSidecarTempDir second = await MihonSidecarTempDir.create(data);
    addTearDown(second.release);

    expect(first.directory.existsSync(), isTrue);
    expect(second.directory.existsSync(), isTrue);
    await first.release();
    expect(first.directory.existsSync(), isFalse);
    expect(second.directory.existsSync(), isTrue);
  });

  test('锁文件在锁上前被别的进程的清扫删掉时换名重建，目录旁总有锁文件', () async {
    // 模拟另一个共用数据目录的进程：在创建方「建好锁文件、还没锁上」的窗口里把锁文件
    // 判成无主并删掉（POSIX 上删除不受打开的句柄阻拦）。修前创建方照样锁住已脱离路径
    // 的文件，建出没有锁文件的目录，下一次清扫就把正在跑的 JVM 的目录删了。
    final List<String> stolen = <String>[];
    MihonSidecarTempDir.debugBeforeLock = (File lockFile) async {
      if (stolen.isNotEmpty) return;
      stolen.add(p.basename(lockFile.path));
      try {
        await lockFile.delete();
      } on FileSystemException {
        // Windows 上创建方开着的文件删不掉，这个窗口本来就不存在。
      }
    };
    addTearDown(() => MihonSidecarTempDir.debugBeforeLock = null);

    final MihonSidecarTempDir tmp = await MihonSidecarTempDir.create(data);
    addTearDown(tmp.release);

    expect(stolen, hasLength(1));
    expect(File('${tmp.directory.path}.lock').existsSync(), isTrue);
    await MihonSidecarTempDir.sweepStale(root());
    expect(tmp.directory.existsSync(), isTrue);
    final List<String> orphanDirs = root()
        .listSync()
        .whereType<Directory>()
        .map((Directory d) => p.basename(d.path))
        .where((String n) => !File(p.join(root().path, '$n.lock')).existsSync())
        .toList();
    expect(orphanDirs, isEmpty);
  });

  test('别的进程锁着的目录不会被清扫', () async {
    final Directory live = Directory(p.join(root().path, 'jvm-7-7-7'))
      ..createSync(recursive: true);
    final File lock = File(p.join(root().path, 'jvm-7-7-7.lock'))
      ..writeAsStringSync('');
    final Process holder = await Process.start('powershell.exe', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "\$f = [IO.File]::Open('${lock.path}', 'Open', 'ReadWrite', "
          "'ReadWrite'); \$f.Lock(0, 1); [Console]::Out.WriteLine('locked'); "
          '[Console]::Out.Flush(); Start-Sleep -Seconds 600',
    ]);
    addTearDown(() async {
      // 结束持有进程，锁随之由操作系统释放。
      holder.kill();
      await holder.exitCode.timeout(const Duration(seconds: 10));
    });
    await holder.stdout
        .transform(utf8.decoder)
        .firstWhere((String s) => s.contains('locked'))
        .timeout(const Duration(seconds: 30));

    await MihonSidecarTempDir.sweepStale(root());

    expect(live.existsSync(), isTrue);
    expect(lock.existsSync(), isTrue);
  }, skip: Platform.isWindows ? false : 'Windows 专属的跨进程锁夹具');

  test('桌面 runtime 把 JVM 临时目录交给 MihonSidecarTempDir，并在进程退出时释放', () {
    final String source = maskComments(
      File(
        'lib/src/media/manga/mihon/desktop_mihon_runtime.dart',
      ).readAsStringSync(),
    );
    expect(
      source,
      matches(RegExp(r'MihonSidecarTempDir\.create\(\s*dataDirectory')),
    );
    expect(source, contains(r"'-Djava.io.tmpdir=${tempDir.directory.path}'"));
    expect(
      source,
      contains('process.exitCode.then((int _) => tempDir.release())'),
    );
  });
}
