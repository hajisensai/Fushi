import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_helper_installer.dart';
import 'package:path/path.dart' as p;

/// BUG-1076 ④ 次生根因的行为测试：换入式安装 [galgameHelperSwapInstall] 必须保证安装目录
/// 「要么完整旧版、要么完整新版」，绝无半覆盖混版本；残骸清扫 [galgameHelperSweepStaleFiles]
/// 只清 `.stale` 后缀、不误伤正常文件。全部走真实临时目录（纯 Dart IO，三平台 CI 可跑）。
void main() {
  late Directory root;
  late Directory staging;
  late Directory target;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hibiki_swap_test_');
    staging = Directory(p.join(root.path, 'staging'))..createSync();
    target = Directory(p.join(root.path, 'target'))..createSync();
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  File write(Directory dir, String rel, String content) {
    final File f = File(p.join(dir.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    return f;
  }

  String read(Directory dir, String rel) =>
      File(p.join(dir.path, rel)).readAsStringSync();

  group('galgameHelperSwapInstall', () {
    test('换入：替换旧文件、落位新增文件、保留子目录结构', () async {
      write(target, 'a.dll', 'old-a');
      write(staging, 'a.dll', 'new-a');
      write(staging, 'b.dll', 'new-b');
      write(staging, p.join('unity_audio_runtime', 'x.bin'), 'new-x');

      await galgameHelperSwapInstall(staging: staging, target: target);

      expect(read(target, 'a.dll'), 'new-a');
      expect(read(target, 'b.dll'), 'new-b');
      expect(read(target, p.join('unity_audio_runtime', 'x.bin')), 'new-x');
    });

    test('成功后不留 .stale 残骸', () async {
      write(target, 'a.dll', 'old-a');
      write(staging, 'a.dll', 'new-a');

      await galgameHelperSwapInstall(staging: staging, target: target);

      final List<String> names = target
          .listSync(recursive: true)
          .whereType<File>()
          .map((File f) => p.basename(f.path))
          .toList();
      expect(names.where(kGalgameHelperStalePattern.hasMatch), isEmpty);
    });

    test('目标目录里换入未触碰的文件（如装机标记）原样保留', () async {
      write(target, 'installed.sha256', 'marker');
      write(staging, 'a.dll', 'new-a');

      await galgameHelperSwapInstall(staging: staging, target: target);

      expect(read(target, 'installed.sha256'), 'marker');
      expect(read(target, 'a.dll'), 'new-a');
    });

    test('中途失败整体回滚：目标回到完整旧版、不留混版本与残骸', () async {
      write(target, 'a.dll', 'old-a');
      write(target, 'b.dll', 'old-b');
      write(staging, 'a.dll', 'new-a');
      write(staging, 'b.dll', 'new-b');

      // 第 2 个文件换入前注入失败（listSync 顺序平台相关，用计数保证恰有 1 个已换入）。
      int calls = 0;
      await expectLater(
        galgameHelperSwapInstall(
          staging: staging,
          target: target,
          onBeforeReplace: (String _) {
            calls++;
            if (calls == 2) throw const FileSystemException('injected');
          },
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(read(target, 'a.dll'), 'old-a');
      expect(read(target, 'b.dll'), 'old-b');
      final List<String> names = target
          .listSync(recursive: true)
          .whereType<File>()
          .map((File f) => p.basename(f.path))
          .toList();
      expect(names.where(kGalgameHelperStalePattern.hasMatch), isEmpty,
          reason: '回滚后 .stale 必须已改回原名');
    });
  });

  group('galgameHelperSweepStaleFiles', () {
    test('清掉 .stale / .staleN 残骸，不误伤正常文件', () {
      write(target, 'a.dll.stale', 'x');
      write(target, 'a.dll.stale2', 'x');
      write(target, p.join('unity_audio_runtime', 'x.bin.stale'), 'x');
      write(target, 'keep.dll', 'keep');
      // 名字含 stale 但不是残骸后缀的不许动。
      write(target, 'stale.dll', 'keep');
      write(target, 'x.staleness', 'keep');

      galgameHelperSweepStaleFiles(target);

      final Set<String> names = target
          .listSync(recursive: true)
          .whereType<File>()
          .map((File f) => p.basename(f.path))
          .toSet();
      expect(names, <String>{'keep.dll', 'stale.dll', 'x.staleness'});
    });

    test('目录不存在时安静返回', () {
      expect(
        () => galgameHelperSweepStaleFiles(
            Directory(p.join(root.path, 'nonexistent'))),
        returnsNormally,
      );
    });
  });
}
