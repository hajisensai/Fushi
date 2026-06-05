import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart';

void main() {
  group('playlistBookUid（纯文件名派生，去掉完整路径哈希）', () {
    test('同一文件名跨不同绝对路径 → 相同 book_uid（不再依赖路径）', () {
      const String a = r'D:\a\list.m3u8';
      const String b = r'D:\b\different\dir\list.m3u8';
      // 关键回归：去掉 sha1(完整路径) 后，同名 m3u8 在任意机器/任意目录身份一致。
      expect(playlistBookUid(a), playlistBookUid(b));
      expect(playlistBookUid(a), 'video/playlist/list');
    });

    test('文件名经 sanitizeTtuFilename 派生（与书一致）', () {
      const String path = r'D:\video\Dragon Maid 观看顺序.m3u8';
      expect(playlistBookUid(path), 'video/playlist/Dragon Maid 观看顺序');
    });

    test('文件名含非法字符走 sanitize（: 等编码）', () {
      // sanitizeTtuFilename 把 `:` 编码成 %3A。
      const String path = r'D:\v\a:b.m3u8';
      expect(playlistBookUid(path), 'video/playlist/a%3Ab');
    });

    test('幂等：同一路径恒得同 uid', () {
      const String path = r'D:\video\list.m3u8';
      expect(playlistBookUid(path), playlistBookUid(path));
    });
  });

  group('singleVideoBookUid（纯文件名派生）', () {
    test('同一文件名跨不同绝对路径 → 相同 book_uid', () {
      const String a = r'D:\a\E01.mkv';
      const String b = r'/home/user/videos/E01.mkv';
      expect(singleVideoBookUid(a), singleVideoBookUid(b));
      expect(singleVideoBookUid(a), 'video/E01');
    });

    test('去扩展名 + sanitize', () {
      expect(singleVideoBookUid(r'D:\v\My Show S01.mp4'), 'video/My Show S01');
    });
  });

  group('uniqueVideoBookUid（同名去重，照搬 EpubImporter 无回调静默加后缀）', () {
    test('无冲突 → 原样返回', () {
      expect(
        uniqueVideoBookUid('video/E01', <String>{}),
        'video/E01',
      );
    });

    test('已存在同名 → 加 (2) 后缀得唯一 book_uid', () {
      expect(
        uniqueVideoBookUid('video/E01', <String>{'video/E01'}),
        'video/E01 (2)',
      );
    });

    test('连续冲突 → 递增到首个空位 (3)', () {
      expect(
        uniqueVideoBookUid('video/E01', <String>{'video/E01', 'video/E01 (2)'}),
        'video/E01 (3)',
      );
    });

    test('playlist book_uid 同样去重', () {
      expect(
        uniqueVideoBookUid(
          'video/playlist/list',
          <String>{'video/playlist/list'},
        ),
        'video/playlist/list (2)',
      );
    });
  });
}
