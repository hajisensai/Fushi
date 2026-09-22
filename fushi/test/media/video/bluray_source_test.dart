import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bluray/bluray_clip_info.dart';
import 'package:fushi_engine/media/video/bluray/bluray_playlist.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart';
import 'package:path/path.dart' as p;

import 'bluray_fixture.dart';

BlurayPlaylist _playlist(List<FixturePlayItem> items) {
  final Uint8List bytes = buildMplsFixture(playItems: items);
  return parseBlurayPlaylist(bytes, id: '00001')!;
}

BlurayClipTimebase _timebase(int startTicks, int endTicks) =>
    BlurayClipTimebase(
      presentationStartTicks: startTicks,
      presentationEndTicks: endTicks,
    );

void main() {
  const String root = '/discs/Movie';
  String stream(String id) => p.join(root, 'BDMV', 'STREAM', '$id.m2ts');

  group('buildBluraySource', () {
    test('单段完整覆盖 → 交真实文件路径，不包 EDL', () {
      final BlurayPlaylist playlist = _playlist(const <FixturePlayItem>[
        FixturePlayItem(
          clipId: '00001',
          inTimeTicks: 45000 * 4,
          outTimeTicks: 45000 * 1804,
        ),
      ]);

      final BluraySource source = buildBluraySource(
        playlist,
        discRootPath: root,
        timebases: <String, BlurayClipTimebase>{
          '00001': _timebase(45000 * 4, 45000 * 1804),
        },
      )!;

      expect(source.isPlainFile, isTrue);
      expect(source.uri, stream('00001'));
      expect(source.primaryStreamPath, stream('00001'));
      expect(source.duration, const Duration(minutes: 30));
    });

    test('零点未知时单段也交文件路径（宁可整段照播）', () {
      final BlurayPlaylist playlist = _playlist(const <FixturePlayItem>[
        FixturePlayItem(
          clipId: '00001',
          inTimeTicks: 45000 * 100,
          outTimeTicks: 45000 * 200,
        ),
      ]);

      final BluraySource source = buildBluraySource(
        playlist,
        discRootPath: root,
        timebases: const <String, BlurayClipTimebase>{},
      )!;

      expect(source.isPlainFile, isTrue);
      expect(source.uri, stream('00001'));
    });

    test('单段但只用中间一截 → EDL 带起止，起点用源文件原始时间戳', () {
      final BlurayPlaylist playlist = _playlist(const <FixturePlayItem>[
        FixturePlayItem(
          clipId: '00001',
          inTimeTicks: 45000 * 70,
          outTimeTicks: 45000 * 130,
        ),
      ]);

      final BluraySource source = buildBluraySource(
        playlist,
        discRootPath: root,
        timebases: <String, BlurayClipTimebase>{
          '00001': _timebase(45000 * 10, 45000 * 3610),
        },
      )!;

      expect(source.isPlainFile, isFalse);
      // EDL 的 start 与源包 PTS 同域：写 70 而不是 70-10。减掉零点会让这一段的包全
      // 部落到段尾之外被丢掉，表现是瞬间 EOF。
      expect(
        source.uri,
        'edl://${encodeEdlField(stream('00001'))},70.000000,60.000000;',
      );
      expect(source.duration, const Duration(minutes: 1));
      // 拼起来播，但抽封面/探容器仍指向真实的第一段。
      expect(source.primaryStreamPath, stream('00001'));
    });

    test('多段拼接：整段用满的段也显式写起止，段长不交给 lavf 估计', () {
      final BlurayPlaylist playlist = _playlist(const <FixturePlayItem>[
        FixturePlayItem(
          clipId: '00001',
          inTimeTicks: 45000 * 10,
          outTimeTicks: 45000 * 610,
        ),
        FixturePlayItem(
          clipId: '00002',
          inTimeTicks: 45000 * 25,
          outTimeTicks: 45000 * 325,
        ),
      ]);

      final BluraySource source = buildBluraySource(
        playlist,
        discRootPath: root,
        timebases: <String, BlurayClipTimebase>{
          // 第一段用满
          '00001': _timebase(45000 * 10, 45000 * 610),
          // 第二段的零点在 5s，且尾部还剩一截没用
          '00002': _timebase(45000 * 5, 45000 * 900),
        },
      )!;

      expect(source.isPlainFile, isFalse);
      expect(
        source.uri,
        'edl://'
        '${encodeEdlField(stream('00001'))},10.000000,600.000000;'
        '${encodeEdlField(stream('00002'))},25.000000,300.000000;',
      );
      expect(source.duration, const Duration(minutes: 15));
    });

    test('多段但零点全未知 → 仍按 MPLS 的 IN / 长度拼接（IN 本就是原始 PTS）', () {
      final BlurayPlaylist playlist = _playlist(const <FixturePlayItem>[
        FixturePlayItem(
          clipId: '00001',
          inTimeTicks: 45000 * 10,
          outTimeTicks: 45000 * 70,
        ),
        FixturePlayItem(
          clipId: '00002',
          inTimeTicks: 45000 * 10,
          outTimeTicks: 45000 * 70,
        ),
      ]);

      final BluraySource source = buildBluraySource(
        playlist,
        discRootPath: root,
        timebases: const <String, BlurayClipTimebase>{},
      )!;

      expect(
        source.uri,
        'edl://'
        '${encodeEdlField(stream('00001'))},10.000000,60.000000;'
        '${encodeEdlField(stream('00002'))},10.000000,60.000000;',
      );
    });

    test('授权工具的几 tick 误差不该把整段判成需要截取', () {
      final BlurayPlaylist playlist = _playlist(const <FixturePlayItem>[
        FixturePlayItem(
          clipId: '00001',
          inTimeTicks: 45000 * 10 + 30,
          outTimeTicks: 45000 * 610 - 30,
        ),
      ]);

      final BluraySource source = buildBluraySource(
        playlist,
        discRootPath: root,
        timebases: <String, BlurayClipTimebase>{
          '00001': _timebase(45000 * 10, 45000 * 610),
        },
      )!;

      expect(source.isPlainFile, isTrue);
    });

    test('章节按播放列表时间轴带出来', () {
      final Uint8List bytes = buildMplsFixture(
        playItems: const <FixturePlayItem>[
          FixturePlayItem(
            clipId: '00001',
            inTimeTicks: 45000 * 4,
            outTimeTicks: 45000 * 604,
          ),
        ],
        marks: const <FixtureMark>[
          FixtureMark(playItemIndex: 0, timestampTicks: 45000 * 4),
          FixtureMark(playItemIndex: 0, timestampTicks: 45000 * 304),
        ],
      );
      final BlurayPlaylist playlist = parseBlurayPlaylist(bytes, id: '00001')!;

      final BluraySource source = buildBluraySource(
        playlist,
        discRootPath: root,
        timebases: const <String, BlurayClipTimebase>{},
      )!;

      expect(source.chapters, <Duration>[
        Duration.zero,
        const Duration(minutes: 5),
      ]);
    });
  });

  group('encodeEdlField', () {
    test('按字节长度前缀，Windows 盘符与逗号不再有歧义', () {
      expect(
        encodeEdlField(r'D:\Movie\BDMV\STREAM\00001.m2ts'),
        r'%31%D:\Movie\BDMV\STREAM\00001.m2ts',
      );
      expect(encodeEdlField('a,b;c'), '%5%a,b;c');
    });

    test('长度算的是 UTF-8 字节而不是字符数', () {
      // 「映画」六字节 + 「.m2ts」五字节
      expect(encodeEdlField('映画.m2ts'), '%11%映画.m2ts');
      expect(utf8Length('映画'), 6);
      expect(utf8Length('a'), 1);
      // 星号 emoji 是代理对，四字节
      expect(utf8Length('\u{1F600}'), 4);
    });
  });

  group('blurayDiscRootForPlaylistPath', () {
    test('认 BDMV/PLAYLIST 下的 mpls', () {
      expect(
        blurayDiscRootForPlaylistPath('/a/Movie/BDMV/PLAYLIST/00001.mpls'),
        p.normalize('/a/Movie'),
      );
    });

    test('不认别处的同名文件', () {
      expect(blurayDiscRootForPlaylistPath('/a/00001.mpls'), isNull);
      expect(
        blurayDiscRootForPlaylistPath('/a/Movie/PLAYLIST/00001.mpls'),
        isNull,
      );
    });
  });

  group('isBlurayPlaylistPath', () {
    test('只认 .mpls，大小写不敏感', () {
      expect(isBlurayPlaylistPath('/a/00001.mpls'), isTrue);
      expect(isBlurayPlaylistPath('/a/00001.MPLS'), isTrue);
      expect(isBlurayPlaylistPath('/a/00001.m2ts'), isFalse);
    });
  });
}
