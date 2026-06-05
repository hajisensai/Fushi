import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:path/path.dart' as p;

/// 龙女仆「观看顺序.m3u8」样例片段：标准扩展 M3U，`#EXTINF:-1,<中文标题>` +
/// 下一行 Windows 反斜杠相对路径（相对 m3u8 所在目录）。
const String _dragonMaidSample = '''
#EXTM3U

#EXTINF:-1,【S1】第01话 史上最强女仆登场！（其实是龙）
Season 01\\Miss Kobayashi's Dragon Maid - S01E01.mkv
#EXTINF:-1,【S1】第02话 第二只龙·康娜！（完全是在惯她了）
Season 01\\Miss Kobayashi's Dragon Maid - S01E02.mkv

#EXTINF:-1,【OVA】情人节与温泉！（请不要期待太多）
Season 00\\Miss Kobayashi's Dragon Maid - S00E01.mkv
''';

void main() {
  group('parseM3u8', () {
    test('解析龙女仆样例：条数/标题/绝对路径（反斜杠归一化）', () {
      const String baseDir = r'D:\video\Miss Kobayashi' 's Dragon Maid';
      final List<PlaylistEntry> entries = parseM3u8(
        content: _dragonMaidSample,
        baseDir: baseDir,
      );

      expect(entries.length, 3);

      expect(entries[0].title, '【S1】第01话 史上最强女仆登场！（其实是龙）');
      expect(entries[1].title, '【S1】第02话 第二只龙·康娜！（完全是在惯她了）');
      expect(entries[2].title, '【OVA】情人节与温泉！（请不要期待太多）');

      // 路径：baseDir + 相对路径（\\ 归一化），用 path 包断言以兼容平台分隔符。
      expect(
        entries[0].path,
        p.normalize(p.join(
          baseDir,
          "Season 01/Miss Kobayashi's Dragon Maid - S01E01.mkv",
        )),
      );
      expect(
        entries[1].path,
        p.normalize(p.join(
          baseDir,
          "Season 01/Miss Kobayashi's Dragon Maid - S01E02.mkv",
        )),
      );
      expect(
        entries[2].path,
        p.normalize(p.join(
          baseDir,
          "Season 00/Miss Kobayashi's Dragon Maid - S00E01.mkv",
        )),
      );
    });

    test('跳过空行与非 EXTINF 注释行', () {
      const String content = '''
#EXTM3U
# 这是一条普通注释，不是 EXTINF

#EXTINF:-1,标题A
a.mkv
#EXTINF:-1,标题B
sub/b.mkv
''';
      final List<PlaylistEntry> entries = parseM3u8(
        content: content,
        baseDir: '/base',
      );
      expect(entries.length, 2);
      expect(entries[0].title, '标题A');
      expect(entries[1].title, '标题B');
    });

    test('无 EXTINF 标题的裸路径行也作为一集（标题回退为文件名）', () {
      const String content = '''
#EXTM3U
plain.mkv
''';
      final List<PlaylistEntry> entries = parseM3u8(
        content: content,
        baseDir: '/base',
      );
      expect(entries.length, 1);
      expect(entries[0].title, 'plain.mkv');
    });

    test('toJson/fromJson 往返', () {
      const PlaylistEntry entry = PlaylistEntry(title: 't', path: '/a/b.mkv');
      final PlaylistEntry round = PlaylistEntry.fromJson(entry.toJson());
      expect(round.title, 't');
      expect(round.path, '/a/b.mkv');
    });
  });
}
