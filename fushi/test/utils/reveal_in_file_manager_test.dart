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

}
