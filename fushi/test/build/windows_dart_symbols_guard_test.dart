// BUG-5568: Windows hang / crash dumps must stay symbolizable.
//
// 2026-11-27 视频页冻结 20.8 s 的 hang dump 里，主线程卡在 GC 标记里，往上 30 多帧 Dart
// 全是裸地址：包里的 app.so 被 gen_snapshot `--strip` 过，dump 也没记 app.so 装在哪
// （Dart 自己的 ELF loader 装的，不进模块表），哪个 Dart 函数在分配无从知道。
//
// 本守卫钉住三件事：
//   * release-desktop.yml 的 Windows 出包另存调试信息（--save-debugging-info，不许换成
//     --split-debug-info），出包后核对 build-id、按发布序号上传 artifact；
//   * runner 把 Dart AOT 镜像的基址 / build-id 写进每份 dump（user stream 类型两边一致）；
//   * flutter_tools 的契约：桌面端默认 --strip、extra-gen-snapshot-options 原样传给
//     gen_snapshot——升级 Flutter 改了这两条就红。
import 'dart:io';

import 'package:test/test.dart';

Directory? _findFlutterRoot() {
  final String? env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && Directory('$env/packages/flutter_tools').existsSync()) {
    return Directory(env);
  }
  Directory dir = File(Platform.resolvedExecutable).parent;
  while (true) {
    if (Directory('${dir.path}/packages/flutter_tools').existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  final String workflow = _read('../.github/workflows/release-desktop.yml');

  String step(String name) {
    final int at = workflow.indexOf('- name: $name\n');
    expect(at, isNonNegative, reason: '缺少步骤「$name」');
    final int next = workflow.indexOf('\n      - name: ', at + 1);
    return workflow.substring(at, next < 0 ? workflow.length : next);
  }

  int at(String name) => workflow.indexOf('- name: $name\n');

  group('BUG-5568 release-desktop.yml 收 Windows Dart 符号', () {
    test('出包命令另存调试信息、不改 app 内栈格式', () {
      final String build = step('Build Windows release');
      expect(
        build,
        contains(
          '--extra-gen-snapshot-options=--save-debugging-info='
          r'${{ github.workspace }}/fushi/build/windows-dart-symbols/app.windows-x64.symbols',
        ),
      );
      expect(
        build,
        isNot(contains('--split-debug-info')),
        reason: '它连带 --dwarf-stack-traces，app 内 Dart 栈会变成 DWARF 形式',
      );
      expect(
        at('Prepare Windows Dart symbols directory'),
        allOf(isNonNegative, lessThan(at('Build Windows release'))),
      );
    });

    test('出包后核对 build-id，再按发布序号上传，都不挡发版', () {
      final String verify = step('Verify Windows Dart symbols');
      expect(
        verify,
        contains(
          'dart tool/windows_dump_symbolize.dart verify '
          'build/windows/x64/runner/Release/data/app.so '
          'build/windows-dart-symbols/app.windows-x64.symbols',
        ),
      );
      expect(verify, contains('continue-on-error: true'));
      final String upload = step('Upload Windows Dart symbols');
      expect(
        upload,
        contains(
          r'name: windows-dart-symbols-${{ steps.channel.outputs.release_sequence }}',
        ),
      );
      expect(upload, contains('path: fushi/build/windows-dart-symbols/'));
      expect(upload, contains('continue-on-error: true'));
      expect(
        upload,
        contains(
          r"retention-days: ${{ steps.channel.outputs.channel == 'debug' && 14 || 90 }}",
        ),
      );
      expect(
        at('Build Windows release'),
        lessThan(at('Verify Windows Dart symbols')),
      );
      expect(
        at('Verify Windows Dart symbols'),
        lessThan(at('Upload Windows Dart symbols')),
      );
    });
  });

  group('BUG-5568 runner 把 Dart AOT 镜像记进 dump', () {
    test('user stream 类型 runner 与还原工具一致', () {
      final String header = _read('windows/runner/dart_aot_image.h');
      final String lib = _read('tool/windows_dump/windows_dump_lib.dart');
      final RegExp native = RegExp(
        r'kDartAotImageStreamType = (0x[0-9A-Fa-f]+);',
      );
      final RegExp dart = RegExp(
        r'const int kDartAotImageStreamType = (0x[0-9A-Fa-f]+);',
      );
      expect(native.firstMatch(header)?[1], isNotNull);
      expect(
        dart.firstMatch(lib)?[1]?.toLowerCase(),
        native.firstMatch(header)![1]!.toLowerCase(),
      );
    });

    test('每份 minidump 都带这条 stream，hang 日志也记一行', () {
      final String crash = _read('windows/runner/crash_dump.cpp');
      expect(crash, contains('aot_stream.Type = kDartAotImageStreamType;'));
      expect(
        crash,
        contains('user_streams.UserStreamCount ? &user_streams : nullptr'),
      );
      final String hang = _read('windows/runner/hang_watchdog.cpp');
      expect(hang, contains('FindDartAotImage(&aot)'));
      expect(hang, contains('CheckWatchdogStarvation(s);'));
    });

    test('镜像定位与看门狗饿死判据进 runner 构建并在构建时执行', () {
      final String cmake = _read('windows/runner/CMakeLists.txt');
      expect(cmake, contains('"dart_aot_image.cpp"'));
      expect(cmake, contains('"tests/dart_aot_image_test.cpp"'));
      expect(
        cmake,
        contains(
          r'add_dependencies(${BINARY_NAME} fushi_windows_dart_aot_image_gate)',
        ),
      );
    });
  });

  group('BUG-5568 依赖的 Flutter SDK 契约', () {
    final Directory? root = _findFlutterRoot();
    test('桌面端 gen_snapshot 默认 --strip，extra-gen-snapshot-options 原样透传', () {
      final String build = _read(
        '${root!.path}/packages/flutter_tools/lib/src/base/build.dart',
      );
      // 不 strip 了就不需要另存；改了透传方式，CI 那条参数可能不再生效。
      expect(build, contains("genSnapshotArgs.add('--strip');"));
      expect(build, contains('genSnapshotArgs.add(option);'));
      // flutter build windows 的产物路径（核对步骤读它）。
      expect(
        build,
        contains("'--snapshot_kind=app-aot-elf', '--elf=\$aotSharedLibrary'"),
      );
    }, skip: root == null ? 'Flutter SDK root not found' : false);
  });
}
