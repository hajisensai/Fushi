import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:test/test.dart';

void main() {
  group('isDiscStreamFilePath（BUG-5280）', () {
    test('蓝光 BDMV/STREAM 下的 m2ts / ssif 是盘内流文件', () {
      expect(
        isDiscStreamFilePath(r'D:\dl\Euphonium\Vol1\BDMV\STREAM\00002.m2ts'),
        isTrue,
      );
      expect(isDiscStreamFilePath('/m/Disc/BDMV/STREAM/00000.M2TS'), isTrue);
      expect(
        isDiscStreamFilePath('/m/Disc/BDMV/STREAM/SSIF/00001.ssif'),
        isTrue,
      );
    });

    test('DVD VIDEO_TS 下的 VOB 是盘内流文件', () {
      expect(isDiscStreamFilePath('/m/Disc/VIDEO_TS/VTS_01_1.VOB'), isTrue);
    });

    test('盘外的 m2ts、盘标题成员、普通视频都不是', () {
      expect(isDiscStreamFilePath('/m/rec/Frieren - 01.m2ts'), isFalse);
      expect(isDiscStreamFilePath('/m/STREAM/00001.m2ts'), isFalse);
      expect(isDiscStreamFilePath('/m/Disc/BDMV/PLAYLIST/00001.mpls'), isFalse);
      expect(isDiscStreamFilePath('/m/Show/Show - 01.mkv'), isFalse);
      expect(isDiscStreamFilePath('/m/misc/clip.vob'), isFalse);
    });
  });
}
