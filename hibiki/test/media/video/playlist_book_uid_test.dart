import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart';

void main() {
  group('playlistBookUid', () {
    test('文件名经 sanitize 派生、稳定、同输入幂等', () {
      const String path = r'D:\video\Dragon Maid 观看顺序.m3u8';
      final String uid = playlistBookUid(path);
      expect(uid, 'video/playlist/Dragon Maid 观看顺序');
      // 幂等：同一路径恒得同 uid。
      expect(playlistBookUid(path), uid);
    });

    test('同名跨不同路径得相同 uid（去掉路径哈希，跨设备稳定）', () {
      const String a = r'D:\a\list.m3u8';
      const String b = r'D:\b\list.m3u8';
      // 身份只看文件名：换目录/换机器不变（去重交给 uniqueVideoBookUid）。
      expect(playlistBookUid(a), playlistBookUid(b));
      expect(playlistBookUid(a), 'video/playlist/list');
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
