import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart' as app;
import 'package:hibiki_core/hibiki_core.dart';

/// 守卫：hibiki_core 的视频 bookUid 派生（v38 拆集迁移用）必须与 app 层
/// `video_import_dialog.dart` 逐字节等价。两处若漂移，迁移拆出的集 uid 会与导入
/// 路径不一致 → 跨设备同步对不齐 / 重复导入不去重。
void main() {
  const List<String> paths = <String>[
    r'D:\a\E01.mkv',
    r'/home/user/videos/E01.mkv',
    r'D:\video\Dragon Maid 観看顺序.m3u8',
    r'D:\v\a:b.m3u8',
    r'D:\v\My Show S01.mp4',
    'plain.mkv',
    r'C:\path\with space\第01話.mkv',
    r'\\server\share\name*star.mkv',
    'trailing ',
    'ending.',
  ];

  test('coreSingleVideoBookUid ≡ app.singleVideoBookUid', () {
    for (final String p in paths) {
      expect(coreSingleVideoBookUid(p), app.singleVideoBookUid(p), reason: p);
    }
  });

  test('corePlaylistBookUid ≡ app.playlistBookUid', () {
    for (final String p in paths) {
      expect(corePlaylistBookUid(p), app.playlistBookUid(p), reason: p);
    }
  });

  test('coreUniqueVideoBookUid ≡ app.uniqueVideoBookUid', () {
    const Set<String> taken = <String>{'video/E01', 'video/E01 (2)'};
    for (final String base in <String>[
      'video/E01',
      'video/fresh',
      'video/E01 (2)'
    ]) {
      expect(
        coreUniqueVideoBookUid(base, taken),
        app.uniqueVideoBookUid(base, taken),
        reason: base,
      );
    }
  });
}
