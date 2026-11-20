// 拍板台 left3568：拖进音乐页——目录登记成音乐来源，曲目文件（纯音频 + MV 视频容器）
// 导入曲库，其余不收；视频侧交给音乐库的口径（只收纯音频）不变。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_file_drop.dart';
import 'package:fushi_engine/media/media_extensions.dart';

void main() {
  test('目录 / 曲目文件（含 MV 视频容器）/ 不收的，按拖入顺序分组', () {
    const Set<String> dirs = <String>{'/m/Album', '/m/MV'};
    final MusicDropPlan plan = planMusicDrop(<String>[
      '/m/Album',
      '/d/Song.flac',
      '/d/Song MV.mkv',
      '/d/Clip.MP4',
      '/d/book.epub',
      '/d/Song.ass',
      '/m/MV',
      '  ',
    ], isDirectory: dirs.contains);
    expect(plan.folders, <String>['/m/Album', '/m/MV']);
    expect(plan.files, <String>[
      '/d/Song.flac',
      '/d/Song MV.mkv',
      '/d/Clip.MP4',
    ]);
    expect(plan.unsupported, <String>['/d/book.epub', '/d/Song.ass']);
    expect(plan.hasAny, isTrue);
  });

  test('只有音乐页不收的文件：hasAny 为 false（落点给提示，不静默）', () {
    final MusicDropPlan plan = planMusicDrop(<String>[
      '/d/a.epub',
      '/d/b.zip',
    ], isDirectory: (_) => false);
    expect(plan.hasAny, isFalse);
    expect(plan.unsupported, hasLength(2));
  });

  test('音乐页口径 = 纯音频 ∪ 视频容器；视频侧交接口径仍只认纯音频', () {
    for (final String p in <String>['/a.flac', '/a.mka', '/a.mkv', '/a.mp4']) {
      expect(isMusicLibraryMediaPath(p), isTrue, reason: p);
    }
    for (final String p in <String>['/a.srt', '/a.epub', '/a', '']) {
      expect(isMusicLibraryMediaPath(p), isFalse, reason: p);
    }
    expect(isAudioOnlyMediaPath('/a.mkv'), isFalse);
    expect(isAudioOnlyMediaPath('/a.mp4'), isFalse);
  });
}
