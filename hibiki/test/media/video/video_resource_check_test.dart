import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_resource_check.dart';

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
}
