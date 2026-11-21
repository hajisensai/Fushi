import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-5088：`RandomAccessFile.readIntoSync` 挡住整个 isolate group 的 GC（源码扫描）。
///
/// `readIntoSync` 在 VM 里经 `Dart_TypedDataAcquireData` 持有目标数组，整段磁盘读期间该线程
/// 不进 GC 安全点。后台 isolate（`Isolate.run` / worker）与 UI isolate 同属一个 isolate group，
/// UI isolate 每次 GC 都得等那块读完——后台视频指纹预热逐块 `readIntoSync` 整个视频库时，
/// 整个界面持续掉帧、偶尔卡死好几秒，而编译、单测都看不出来。
///
/// 要整文件哈希用 `ffcSha256FileSync` / `ffcCrc32FileSync`（读盘在 Rust，非叶 FFI，全程 native
/// 态）；要读一段字节用 `readSync(n)`（读盘期间处于 native 态）或异步 `readInto`（在 IO 线程读）。
void main() {
  final List<Directory> roots = <Directory>[
    Directory('lib'),
    for (final FileSystemEntity e in Directory('../packages').listSync())
      if (e is Directory) Directory('${e.path}/lib'),
  ];

  List<File> dartFiles() => <File>[
    for (final Directory root in roots)
      if (root.existsSync())
        for (final FileSystemEntity e in root.listSync(recursive: true))
          if (e is File && e.path.endsWith('.dart')) e,
  ];

  test('guard sees the app and package sources (not vacuous)', () {
    final List<File> files = dartFiles();
    expect(files.length, greaterThan(2000));
    expect(
      files.any(
        (File f) => f.path
            .replaceAll('\\', '/')
            .endsWith('fushi_compute/lib/src/hash/ffc_hash.dart'),
      ),
      isTrue,
    );
  });

  test('no readIntoSync in app or package code (blocks GC safepoints)', () {
    final RegExp call = RegExp(r'\.readIntoSync\s*\(');
    final List<String> offenders = <String>[
      for (final File f in dartFiles())
        if (call.hasMatch(maskComments(f.readAsStringSync()))) f.path,
    ];
    expect(
      offenders,
      isEmpty,
      reason:
          'readIntoSync 整段读盘期间挡住整个 isolate group 的 GC，UI 会跟着卡'
          '（BUG-5088）。整文件哈希用 ffcSha256FileSync / ffcCrc32FileSync，'
          '读字节用 readSync(n) 或异步 readInto。',
    );
  });
}
