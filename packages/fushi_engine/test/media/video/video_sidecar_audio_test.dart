import 'package:fushi_engine/media/video/video_sidecar.dart';
import 'package:test/test.dart';

void main() {
  group('listSidecarAudioTracks', () {
    test('同目录带语言标记 / 无标记的外挂音轨都认，字幕与视频本身不算', () {
      final List<SidecarAudioTrack> got = listSidecarAudioTracks(
        'ep01',
        <String>[
          'ep01.mkv',
          'ep01.jpn.mka',
          'ep01.flac',
          'ep01.ja.ass',
          'ep02.jpn.mka',
        ],
      );
      expect(got, <SidecarAudioTrack>[
        (relativePath: 'ep01.jpn.mka', tag: 'jpn'),
        (relativePath: 'ep01.flac', tag: null),
      ]);
    });

    test('下划线分隔的发布组命名 + 直接子目录里的外挂音轨', () {
      final List<SidecarAudioTrack> got = listSidecarAudioTracks(
        'Movie',
        <String>['Movie.mkv', 'Movie_Eng_Audio_5.1.mka'],
        childDirFiles: <String, List<String>>{
          'Audio 5.1': <String>['Movie_Commentary.dts', 'Other.mka'],
        },
      );
      expect(got, <SidecarAudioTrack>[
        (relativePath: 'Movie_Eng_Audio_5.1.mka', tag: 'Eng_Audio_5.1'),
        (relativePath: 'Audio 5.1/Movie_Commentary.dts', tag: 'Commentary'),
      ]);
    });

    test('最长主干认领：Show 01v2 的音轨不归 Show 01', () {
      final List<String> dir = <String>[
        'Show 01.mkv',
        'Show 01v2.mkv',
        'Show 01v2.jpn.mka',
        'Show 01.jpn.mka',
      ];
      expect(listSidecarAudioTracks('Show 01', dir), <SidecarAudioTrack>[
        (relativePath: 'Show 01.jpn.mka', tag: 'jpn'),
      ]);
      expect(listSidecarAudioTracks('Show 01v2', dir), <SidecarAudioTrack>[
        (relativePath: 'Show 01v2.jpn.mka', tag: 'jpn'),
      ]);
    });

    test('纯数字主干不认子目录里的同号文件（CDs/01.flac 是专辑曲目）', () {
      final List<SidecarAudioTrack> got = listSidecarAudioTracks(
        '01',
        <String>['01.mkv', '01.flac'],
        childDirFiles: <String, List<String>>{
          'CDs': <String>['01.flac'],
        },
      );
      expect(got, <SidecarAudioTrack>[(relativePath: '01.flac', tag: null)]);
    });

    test('非音频扩展名、主干后不是分隔符的都不算', () {
      expect(
        listSidecarAudioTracks('ep1', <String>[
          'ep1.mkv',
          'ep1.nfo',
          'ep10.mka',
          'ep1.jpg',
        ]),
        isEmpty,
      );
    });
  });

  group('sidecarAudioLabel', () {
    test('语言码取首段 2–3 个字母，名字把下划线换空格', () {
      expect(sidecarAudioLabel('Eng_Audio_5.1', 'x.mka'), (
        label: 'Eng Audio 5.1',
        language: 'eng',
      ));
      expect(sidecarAudioLabel('jpn', 'x.mka'), (
        label: 'jpn',
        language: 'jpn',
      ));
      expect(sidecarAudioLabel('Commentary', 'x.mka'), (
        label: 'Commentary',
        language: null,
      ));
    });

    test('没有标记时用文件名', () {
      expect(sidecarAudioLabel(null, 'ep01.flac'), (
        label: 'ep01.flac',
        language: null,
      ));
    });
  });
}
