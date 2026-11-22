import 'package:fushi_engine/media/media_extensions.dart';
import 'package:test/test.dart';

/// 取扩展名的热路径（视频库每次重建对全库逐行判音频）改成不走 `Uri.tryParse`、
/// 不现编正则之后，判定结果必须与旧实现逐字一致。
void main() {
  group('isAudioOnlyMediaPath / isVideoMediaPath', () {
    test('Windows 与 POSIX 本地路径、大小写不敏感', () {
      expect(isAudioOnlyMediaPath(r'D:\music\Album\01 Track.FLAC'), isTrue);
      expect(isAudioOnlyMediaPath('/home/u/music/a.mp3'), isTrue);
      expect(isVideoMediaPath(r'D:\video\Show\S01E01.MKV'), isTrue);
      expect(isAudioOnlyMediaPath(r'D:\video\Show\S01E01.mkv'), isFalse);
      expect(isVideoMediaPath(r'\\nas\share\movie.mp4'), isTrue);
    });

    test('目录名带点、文件名无扩展名 → 不是媒体', () {
      expect(isAudioOnlyMediaPath(r'D:\music.flac\track'), isFalse);
      expect(isVideoMediaPath('/srv/v1.0/README'), isFalse);
    });

    test('隐藏文件（只有前导点）不算扩展名', () {
      expect(isAudioOnlyMediaPath('/x/.mp3'), isFalse);
      expect(isAudioOnlyMediaPath(r'C:\x\.flac'), isFalse);
    });

    test('http(s) URL 取路径段，去掉查询串与片段，scheme 大小写不敏感', () {
      expect(isAudioOnlyMediaPath('https://h/a/b.mp3?sig=abc.mkv'), isTrue);
      expect(isVideoMediaPath('HTTP://h/v/ep.mkv#t=10'), isTrue);
      expect(isVideoMediaPath('https://h/v/ep?f=x.mkv'), isFalse);
    });

    test('非 http scheme 当普通路径', () {
      expect(isVideoMediaPath('file:///D:/v/a.mkv'), isTrue);
      expect(isAudioOnlyMediaPath('smb://nas/a.flac'), isTrue);
    });

    test('空串 / 空白', () {
      expect(isAudioOnlyMediaPath(''), isFalse);
      expect(isVideoMediaPath('   '), isFalse);
      expect(isAudioOnlyMediaPath('  D:/a.mp3  '), isTrue);
    });
  });
}
