import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/external_video.dart';

void main() {
  group('isSupportedVideoFile', () {
    test('常见容器格式都受支持（大小写不敏感）', () {
      const List<String> ok = <String>[
        'D:/v/a.mkv',
        'D:/v/a.MP4',
        '/home/u/b.webm',
        'c.MOV',
        'd.avi',
        'e.ts',
        'f.m4v',
        'g.flv',
        'h.wmv',
      ];
      for (final String path in ok) {
        expect(isSupportedVideoFile(path), isTrue, reason: path);
      }
    });

    test('非视频扩展名一律拒绝', () {
      const List<String> bad = <String>[
        'a.zip',
        'b.epub',
        'c.srt',
        'd.txt',
        'noext',
        'e.',
        '',
      ];
      for (final String path in bad) {
        expect(isSupportedVideoFile(path), isFalse, reason: path);
      }
    });
  });

  group('externalVideoBookUid', () {
    test('同路径稳定、幂等', () {
      const String path = 'D:/video/Dragon Maid/S01E01.mkv';
      expect(externalVideoBookUid(path), externalVideoBookUid(path));
      expect(externalVideoBookUid(path), startsWith('video/ext/'));
    });

    test('反斜杠与正斜杠派生同一 uid', () {
      expect(
        externalVideoBookUid(r'D:\video\a.mkv'),
        externalVideoBookUid('D:/video/a.mkv'),
      );
    });

    test('规范化冗余路径段后等价', () {
      expect(
        externalVideoBookUid('D:/video/./sub/../a.mkv'),
        externalVideoBookUid('D:/video/a.mkv'),
      );
    });

    test('不同文件不同 uid', () {
      expect(
        externalVideoBookUid('D:/video/a.mkv'),
        isNot(externalVideoBookUid('D:/video/b.mkv')),
      );
    });

    test('与导入对话框的 video/<basename> 命名前缀区分', () {
      // 外部打开用 video/ext/ 前缀，不会与手动导入的 video/<basename> 撞键。
      expect(externalVideoBookUid('D:/v/a.mkv'), startsWith('video/ext/'));
    });
  });

  group('firstExternalVideoArg', () {
    test('挑出第一个视频参数', () {
      expect(
        firstExternalVideoArg(<String>['D:/v/a.mkv']),
        'D:/v/a.mkv',
      );
    });

    test('跳过 flag 参数', () {
      expect(
        firstExternalVideoArg(<String>['--observatory', '-d', 'D:/v/a.mkv']),
        'D:/v/a.mkv',
      );
    });

    test('跳过非视频参数，挑出后面的视频', () {
      expect(
        firstExternalVideoArg(<String>['some.txt', 'D:/v/a.mp4']),
        'D:/v/a.mp4',
      );
    });

    test('无视频参数返回 null', () {
      expect(firstExternalVideoArg(<String>[]), isNull);
      expect(firstExternalVideoArg(<String>['--flag', 'x.txt']), isNull);
    });
  });
}
