import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/media_extensions.dart';
import 'package:fushi/src/media/video/external_video.dart';

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

    test('白名单 = kVideoExtensions ∪ {3gp}（防第三份表再漂移）', () {
      // 能导入的每个扩展名都能从 app 外打开（此前 .rmvb/.rm/.vob 漂移缺失）。
      for (final String ext in kVideoExtensions) {
        expect(isSupportedVideoFile('D:/v/a$ext'), isTrue,
            reason: '$ext 可导入但不可外开：外开白名单与 kVideoExtensions 漂移');
      }
      // 显式差异项：.3gp 只在外开白名单（导入表暂不收录，见 external_video.dart）。
      expect(isSupportedVideoFile('D:/v/a.3gp'), isTrue);
      expect(kVideoExtensions.contains('.3gp'), isFalse,
          reason: '.3gp 已进导入表，请把 external_video.dart 的显式增项与本断言一并清理');
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
  group('sourceEntryBasename / decodedSourceBasename 的编码状态分工', () {
    // 背景（#908 审查）：来源库条目路径**已经是解码态**——WebDAV 的 PROPFIND href
    // 在 webdav_ops.dart 就 Uri.decodeFull 过了，SFTP/FTP 路径本就不是百分号编码。
    // 生产上有两个落点会对它再解一次：漫画远端镜像的查找表构建，以及
    // NetworkSourceFileSystem.copyToLocal 派生本地文件名（经 _urlBasename，现已
    // 收敛到 sourceEntryBasename）。再解一次的两种后果都在下面钉住。
    test('不解码：真名含 % 不抛异常（旧实现在这里 ArgumentError）', () {
      // 断言字面量：'50% off.jpg'
      expect(sourceEntryBasename('https://h/m/Odd/50% off.jpg'), '50% off.jpg');
      expect(sourceEntryBasename('https://h/m/100%.jpg'), '100%.jpg');
      // 旧实现走 Uri.decodeComponent / Uri.parse().pathSegments，对上面这两个
      // 输入直接抛 ArgumentError: Invalid URL encoding。
    });

    test('不解码：真名里的 %20 是字面量，不能被解成空格', () {
      // 断言字面量：'p%20a.jpg'（解成 'p a.jpg' 就与 mokuro 的 img_path 对不上）
      expect(sourceEntryBasename('https://h/m/Odd/p%20a.jpg'), 'p%20a.jpg');
    });

    test('字面空格与中文原样返回', () {
      expect(sourceEntryBasename('https://h/m/Show A/Show A S01E01.mkv'),
          'Show A S01E01.mkv');
      expect(sourceEntryBasename('https://h/m/第1話 表紙.jpg'), '第1話 表紙.jpg');
    });

    test('反斜杠与正斜杠都算分隔符，无分隔符时返回整串', () {
      expect(sourceEntryBasename(r'D:\v\a.mkv'), 'a.mkv');
      expect(sourceEntryBasename('a.mkv'), 'a.mkv');
    });

    test('decodedSourceBasename 仍为「尚未解码的 URL」保留解码语义', () {
      // 用户粘贴的地址、m3u8 清单里的原始行走这条；两个函数分工不能混。
      expect(decodedSourceBasename('https://h/v/clip%201.mkv'), 'clip 1.mkv');
      // 非法编码时它有 try/catch 兜底，返回原串而不是抛。
      expect(decodedSourceBasename('https://h/v/50% off.mkv'), '50% off.mkv');
      // 本地路径不解码。
      expect(decodedSourceBasename(r'D:\v\p%20a.mkv'), 'p%20a.mkv');
    });
  });
}
