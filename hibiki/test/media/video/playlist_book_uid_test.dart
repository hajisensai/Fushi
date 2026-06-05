import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart';

void main() {
  group('playlistBookUid', () {
    test('前缀含文件名、稳定、同输入幂等', () {
      const String path = r'D:\video\Dragon Maid 观看顺序.m3u8';
      final String uid = playlistBookUid(path);
      expect(uid.startsWith('video/playlist/Dragon Maid 观看顺序_'), isTrue);
      // 幂等：同一路径恒得同 uid。
      expect(playlistBookUid(path), uid);
    });

    test('不同路径得不同 uid（哈希区分同名）', () {
      const String a = r'D:\a\list.m3u8';
      const String b = r'D:\b\list.m3u8';
      expect(playlistBookUid(a), isNot(playlistBookUid(b)));
      // 但前缀相同（同文件名）。
      expect(playlistBookUid(a).startsWith('video/playlist/list_'), isTrue);
      expect(playlistBookUid(b).startsWith('video/playlist/list_'), isTrue);
    });
  });

  group('videoCoverFileName', () {
    test('单视频 bookUid 的 / 归一成 _，以 .jpg 结尾', () {
      expect(videoCoverFileName('video/E01.mkv'), 'video_E01.mkv.jpg');
    });

    test('playlist bookUid 的 / 全部归一（无路径分隔符）', () {
      const String uid = 'video/playlist/list_abc123def456';
      final String name = videoCoverFileName(uid);
      expect(name, 'video_playlist_list_abc123def456.jpg');
      // 不含任何路径分隔符或 Windows 非法字符。
      expect(name.contains('/'), isFalse);
      expect(name.contains(r'\'), isFalse);
    });

    test('Windows 非法字符（: * ? 等）一并归一', () {
      expect(videoCoverFileName('video/a:b*c?.mkv'), 'video_a_b_c_.mkv.jpg');
    });
  });
}
