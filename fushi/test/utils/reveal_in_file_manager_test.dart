import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/utils/misc/reveal_in_file_manager.dart';

/// 文件管理器 reveal 原语的 per-host argv 形状与退出码策略。
///
/// 这些用例原本挂在视频下载面板的测试里；原语搬到 `utils/misc` 后随之搬家——书架
/// 「打开文件位置」与下载面板现在共用同一份实现，argv 形状只有这一处需要守住。
void main() {
  group('reveal command', () {
    test('windows keeps /select, and the path as separate arguments', () {
      final RevealCommand command = revealCommand(
        host: RevealHost.windows,
        path: r'D:\media\Show S01E01.mkv',
        isDirectory: false,
      );

      expect(command.executable, 'explorer');
      // Measured on Windows 11: joining these into one argument makes Dart
      // quote it ("/select,D:\media\Show S01E01.mkv") and explorer answers by
      // opening Documents. Split, it selects the file every time.
      expect(
          command.arguments, <String>['/select,', r'D:\media\Show S01E01.mkv']);
    });

    test('windows explorer exit codes carry no success signal', () {
      expect(
        revealCommand(
          host: RevealHost.windows,
          path: r'D:\media\Show S01E01.mkv',
          isDirectory: false,
        ).exitCodeIsMeaningful,
        isFalse,
      );
      expect(
        revealCommand(
          host: RevealHost.macos,
          path: '/media/Show S01E01.mkv',
          isDirectory: false,
        ).exitCodeIsMeaningful,
        isTrue,
      );
    });

    test('windows reveal succeeds although explorer.exe exits with 1',
        () async {
      String? executable;
      List<String>? arguments;
      final bool revealed = await revealInFileManagerOn(
        r'D:\media\Show S01E01.mkv',
        host: RevealHost.windows,
        typeOf: (String _) async => FileSystemEntityType.file,
        run: (String value, List<String> args) async {
          executable = value;
          arguments = args;
          // explorer.exe returns 1 even when it opened and selected the file.
          return ProcessResult(0, 1, '', '');
        },
      );

      expect(revealed, isTrue);
      expect(executable, 'explorer');
      expect(arguments, <String>['/select,', r'D:\media\Show S01E01.mkv']);
    });

    test('a failing exit code still fails where it means something', () async {
      expect(
        await revealInFileManagerOn(
          '/media/Show S01E01.mkv',
          host: RevealHost.macos,
          typeOf: (String _) async => FileSystemEntityType.file,
          run: (String _, List<String> __) async => ProcessResult(0, 1, '', ''),
        ),
        isFalse,
      );
    });

    test('a host without a file manager never spawns anything', () async {
      bool spawned = false;
      final bool revealed = await revealInFileManagerOn(
        '/storage/emulated/0/Show S01E01.mkv',
        host: null,
        typeOf: (String _) async => FileSystemEntityType.file,
        run: (String _, List<String> __) async {
          spawned = true;
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(revealed, isFalse);
      expect(spawned, isFalse);
    });

    test('a missing path never spawns anything', () async {
      bool spawned = false;
      final bool revealed = await revealInFileManagerOn(
        r'D:\media\gone.mkv',
        host: RevealHost.windows,
        typeOf: (String _) async => FileSystemEntityType.notFound,
        run: (String _, List<String> __) async {
          spawned = true;
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(revealed, isFalse);
      expect(spawned, isFalse);
    });
  });

  /// 「主产物 → 退回它所在的容器」这条候选链是三个库页共用的形状：视频行是
  /// `videoPath` + 播放列表各集，游戏条目是 exe + 工作目录。守住三条不变量：
  /// 短路（第一条成功就不再骚扰文件管理器）、顺延（前面的没了继续试后面的）、
  /// 空串不是候选（缺失字段不该白跑一次 reveal）。
  group('revealFirstOf', () {
    test('第一条成功就停手，不再试后面的候选', () async {
      final List<String> tried = <String>[];
      final bool revealed = await revealFirstOf(
        <String>[r'D:\games\game.exe', r'D:\games'],
        reveal: (String path) async {
          tried.add(path);
          return true;
        },
      );

      expect(revealed, isTrue);
      expect(tried, <String>[r'D:\games\game.exe']);
    });

    test('首选打不开时顺延到下一条候选', () async {
      final List<String> tried = <String>[];
      final bool revealed = await revealFirstOf(
        <String>[r'D:\games\gone.exe', r'D:\games'],
        reveal: (String path) async {
          tried.add(path);
          return path == r'D:\games';
        },
      );

      expect(revealed, isTrue);
      expect(tried, <String>[r'D:\games\gone.exe', r'D:\games']);
    });

    test('空串与纯空白不是候选，不会白跑一次 reveal', () async {
      final List<String> tried = <String>[];
      final bool revealed = await revealFirstOf(
        <String>['', '   ', r'D:\games'],
        reveal: (String path) async {
          tried.add(path);
          return true;
        },
      );

      expect(revealed, isTrue);
      expect(tried, <String>[r'D:\games']);
    });

    test('全都打不开返回 false，调用方据此提示', () async {
      expect(
        await revealFirstOf(
          <String>[r'D:\games\gone.exe', r'D:\gone'],
          reveal: (String _) async => false,
        ),
        isFalse,
      );
      expect(
        await revealFirstOf(
          const <String>[],
          reveal: (String _) async => true,
        ),
        isFalse,
        reason: '没有任何候选 = 定位不到，不能返回成功',
      );
    });
  });

  // BUG-3090：来源根目录可以是符号链接 / 联接点。按 followLinks:false 判类型时它是
  // link 而不是 directory，Windows 会变成 explorer /select（在父目录里选中它），
  // 而不是打开这个文件夹。
  group('openDirectoryInFileManager', () {
    Future<(bool, List<List<String>>)> open(
      String path, {
      required RevealHost? host,
    }) async {
      final List<List<String>> calls = <List<String>>[];
      final bool opened = await openDirectoryInFileManagerOn(
        path,
        host: host,
        typeOf: followingLinkEntityType,
        run: (String executable, List<String> args) async {
          calls.add(<String>[executable, ...args]);
          return ProcessResult(0, executable == 'explorer' ? 1 : 0, '', '');
        },
      );
      return (opened, calls);
    }

    test('指向目录的符号链接按目录打开，不 /select', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('fushi_rev_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final Directory real = Directory('${tmp.path}/real')..createSync();
      final Link link = Link('${tmp.path}/root')..createSync(real.path);

      // 旧判据（revealInFileManager 用的 followLinks:false）确实把它当 link。
      expect(
        await FileSystemEntity.type(link.path, followLinks: false),
        FileSystemEntityType.link,
      );

      final (bool winOpened, List<List<String>> winCalls) = await open(
        link.path,
        host: RevealHost.windows,
      );
      expect(winOpened, isTrue);
      expect(winCalls.single.first, 'explorer');
      expect(winCalls.single, isNot(contains('/select,')));

      final (bool linuxOpened, List<List<String>> linuxCalls) = await open(
        link.path,
        host: RevealHost.linux,
      );
      expect(linuxOpened, isTrue);
      expect(linuxCalls.single, <String>['xdg-open', link.path]);
    }, skip: Platform.isWindows ? 'Link.createSync 在 Windows 需要特权' : false);

    test('不存在 / 悬空链接 / 普通文件都返回 false，且不启动文件管理器', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('fushi_rev_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final File file = File('${tmp.path}/a.mkv')..writeAsStringSync('x');
      final List<String> paths = <String>[
        '${tmp.path}/gone',
        file.path,
        if (!Platform.isWindows)
          (Link(
            '${tmp.path}/dangling',
          )..createSync('${tmp.path}/nowhere')).path,
      ];
      for (final String path in paths) {
        final (bool opened, List<List<String>> calls) = await open(
          path,
          host: RevealHost.linux,
        );
        expect(opened, isFalse, reason: path);
        expect(calls, isEmpty, reason: path);
      }
    });

    test('移动端没有文件管理器契约', () async {
      final (bool opened, List<List<String>> calls) = await open(
        Directory.systemTemp.path,
        host: null,
      );
      expect(opened, isFalse);
      expect(calls, isEmpty);
    });

    test('xdg-open 失败如实返回 false', () async {
      final bool opened = await openDirectoryInFileManagerOn(
        Directory.systemTemp.path,
        host: RevealHost.linux,
        typeOf: followingLinkEntityType,
        run: (String _, List<String> __) async => ProcessResult(0, 4, '', ''),
      );
      expect(opened, isFalse);
    });
  });
}
