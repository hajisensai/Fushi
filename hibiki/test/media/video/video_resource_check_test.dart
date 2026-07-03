import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_resource_check.dart';
import 'package:path/path.dart' as p;

void main() {
  group('videoResourceRequiresLocalCheck (TODO-897 纯函数)', () {
    test('null / 空 / 空白 路径不校验（远端 / 未知）', () {
      expect(videoResourceRequiresLocalCheck(null), isFalse);
      expect(videoResourceRequiresLocalCheck(''), isFalse);
      expect(videoResourceRequiresLocalCheck('   '), isFalse);
    });

    test('http/https 流 URL 豁免（不校验）', () {
      expect(
        videoResourceRequiresLocalCheck('https://cdn.example.com/a.m3u8'),
        isFalse,
      );
      expect(
        videoResourceRequiresLocalCheck('http://host/video.mp4'),
        isFalse,
      );
      expect(
        videoResourceRequiresLocalCheck('HTTPS://Host/a.ts'),
        isFalse,
      );
    });

    test('本地绝对路径 / file:// 需校验（true）', () {
      expect(
        videoResourceRequiresLocalCheck(r'D:\movies\ep01.mkv'),
        isTrue,
      );
      expect(
        videoResourceRequiresLocalCheck('/home/user/ep01.mp4'),
        isTrue,
      );
      // file:// 不是 http(s) 流，按本地处理需校验。
      expect(
        videoResourceRequiresLocalCheck('file:///tmp/a.mp4'),
        isTrue,
      );
    });
  });

  group('isLocalVideoResourceMissing (TODO-897 异步)', () {
    test('流 / 远端 / 空 恒不缺失（豁免，照常 load）', () async {
      expect(await isLocalVideoResourceMissing(null), isFalse);
      expect(await isLocalVideoResourceMissing(''), isFalse);
      expect(
        await isLocalVideoResourceMissing('https://host/a.m3u8'),
        isFalse,
      );
    });

    test('真实存在的本地文件 → 不缺失（回归守卫：不误判活资源）', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('todo897_present');
      addTearDown(() => dir.delete(recursive: true));
      final File f = File('${dir.path}/present.mp4');
      await f.writeAsString('fake video bytes');
      expect(await f.exists(), isTrue);
      expect(await isLocalVideoResourceMissing(f.path), isFalse);
    });

    test('被删除 / 不存在的本地路径 → 缺失', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('todo897_missing');
      addTearDown(() => dir.delete(recursive: true));
      final File f = File('${dir.path}/gone.mp4');
      await f.writeAsString('x');
      await f.delete();
      expect(await f.exists(), isFalse);
      expect(await isLocalVideoResourceMissing(f.path), isTrue);
      // 整盘 / 父目录不存在的纯虚构路径同样判缺失。
      expect(
        await isLocalVideoResourceMissing('${dir.path}/never/created.mp4'),
        isTrue,
      );
    });
  });

  group('relocateMissingAppDocumentPath', () {
    test(
        'repairs stale iOS app-container Documents paths when same relative file exists',
        () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('todo897_relocate');
      addTearDown(() => dir.delete(recursive: true));
      final Directory currentDocs = Directory(
        '${dir.path}/Containers/Data/Application/NEW/Documents',
      )..createSync(recursive: true);
      final File current = File('${currentDocs.path}/codex/movie.mp4')
        ..createSync(recursive: true);
      final String stale =
          '${dir.path}/Containers/Data/Application/OLD/Documents/codex/movie.mp4';

      expect(await File(stale).exists(), isFalse);
      // 源码用 package:path 的 `p.join` 重建绝对路径（跨平台正确：Windows 产出
      // `\`，POSIX 产出 `/`）。断言用 `p.equals` 做平台无关比较，别写死分隔符，
      // 否则 Windows 上会把语义相等的 `\` 路径误判为不等。
      final String? relocated = await relocateMissingAppDocumentPath(
        stale,
        documentsRoot: currentDocs,
      );
      expect(relocated, isNotNull);
      expect(p.equals(relocated!, current.path), isTrue);
    });

    test('does not repoint arbitrary user Documents paths', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('todo897_no_relocate');
      addTearDown(() => dir.delete(recursive: true));
      final Directory currentDocs = Directory(
        '${dir.path}/Containers/Data/Application/NEW/Documents',
      )..createSync(recursive: true);
      File('${currentDocs.path}/movie.mp4').createSync();

      expect(
        await relocateMissingAppDocumentPath(
          '${dir.path}/Users/alice/Documents/movie.mp4',
          documentsRoot: currentDocs,
        ),
        isNull,
      );
    });
  });
}
