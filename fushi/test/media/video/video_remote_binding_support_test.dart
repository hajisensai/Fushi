import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_remote_binding_support.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi_anki/fushi_anki.dart' show MiningRequestOverrides;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';

/// BUG-3878：遥控绑定共用件（原生播放器页 / 内置网页播放器页 / app 内浏览器共用）。
AudioCue _cue(int start, int end, String text) => AudioCue()
  ..bookKey = ''
  ..chapterHref = ''
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = start
  ..endMs = end
  ..audioFileIndex = 0;

FavoriteSentence _favorite(String text, int? at) => FavoriteSentence(
  text: text,
  bookTitle: 'b',
  createdAt: DateTime(2026),
  bookKey: 'video/stream/x',
  normCharOffset: at,
);

Matcher _remoteError(int status, String code) => isA<VideoRemoteException>()
    .having((VideoRemoteException e) => e.status, 'status', status)
    .having((VideoRemoteException e) => e.code, 'code', code);

void main() {
  group('VideoRemoteCueCache', () {
    test('主副两流按播放器轴（含调轴）合并排序，id 带流名与原始下标', () {
      final VideoRemoteCueCache cache = VideoRemoteCueCache();
      final List<VideoRemoteCue> rows = cache.read(
        primary: <AudioCue>[_cue(1000, 2000, 'a'), _cue(5000, 6000, 'b')],
        secondary: <AudioCue>[_cue(2500, 3000, 'x')],
        secondaryDelayMs: 1000,
      );
      expect(rows.map((VideoRemoteCue r) => r.id).toList(), <String>[
        'primary:0',
        'secondary:0',
        'primary:1',
      ]);
      expect(rows[1].delayMs, 1000);
      expect(rows[1].track, 'secondary');
    });

    test('输入不变读缓存；换轨 key 或调轴就重建', () {
      final VideoRemoteCueCache cache = VideoRemoteCueCache();
      final List<AudioCue> cues = <AudioCue>[_cue(0, 10, 'a')];
      final List<VideoRemoteCue> first = cache.read(primary: cues, key: 'k1');
      expect(identical(cache.read(primary: cues, key: 'k1'), first), isTrue);
      expect(identical(cache.read(primary: cues, key: 'k2'), first), isFalse);
      final List<VideoRemoteCue> delayed = cache.read(
        primary: cues,
        key: 'k2',
        primaryDelayMs: 300,
      );
      expect(delayed.single.delayMs, 300);
    });
  });

  group('parseVideoRemoteMineRequest', () {
    test('取出字段与句子', () {
      final VideoRemoteMineRequest r = parseVideoRemoteMineRequest(
        <String, dynamic>{
          'rawFields': <String, dynamic>{'expression': '猫', 'reading': 'ねこ'},
          'sentence': '猫がいる',
        },
      );
      expect(r.fields['expression'], '猫');
      expect(r.sentence, '猫がいる');
    });

    test('缺 rawFields / 空词条 / 句子不是字符串都回 400', () {
      expect(
        () => parseVideoRemoteMineRequest(<String, dynamic>{}),
        throwsA(_remoteError(400, 'invalid_fields')),
      );
      expect(
        () => parseVideoRemoteMineRequest(<String, dynamic>{
          'rawFields': <String, dynamic>{'expression': '  '},
        }),
        throwsA(_remoteError(400, 'invalid_fields')),
      );
      expect(
        () => parseVideoRemoteMineRequest(<String, dynamic>{
          'rawFields': <String, dynamic>{'expression': '猫'},
          'sentence': 3,
        }),
        throwsA(_remoteError(400, 'invalid_fields')),
      );
    });

    test('dictionaryMedia 在解析入口统一清洗：越级路径进不了任何一条遥控制卡路径', () {
      final VideoRemoteMineRequest r = parseVideoRemoteMineRequest(
        <String, dynamic>{
          'rawFields': <String, dynamic>{
            'expression': '猫',
            'dictionaryMedia': jsonEncode(<Map<String, String>>[
              <String, String>{'dictionary': 'd', 'path': 'img/a.png'},
              <String, String>{'dictionary': 'd', 'path': 'a.x/../../evil'},
            ]),
          },
        },
      );
      final List<dynamic> media =
          jsonDecode(r.fields['dictionaryMedia']!) as List<dynamic>;
      expect(media, hasLength(1));
      expect((media.single as Map<String, dynamic>)['path'], 'img/a.png');
      // 没带就不凭空加。
      expect(
        parseVideoRemoteMineRequest(<String, dynamic>{
          'rawFields': <String, dynamic>{'expression': '猫'},
        }).fields.containsKey('dictionaryMedia'),
        isFalse,
      );
    });

    test('覆盖项从 rawFields 同步读出（调用方在首个 await 之前拿到）', () {
      final VideoRemoteMineRequest r = parseVideoRemoteMineRequest(
        <String, dynamic>{
          'rawFields': <String, dynamic>{
            'expression': '猫',
            MiningRequestOverrides.wireKey: jsonEncode(
              const MiningRequestOverrides(omitAudio: true).toJson(),
            ),
          },
        },
      );
      expect(r.overrides?.omitAudio, isTrue);
    });
  });

  test('sanitizeVideoRemoteDictionaryMediaJson 丢掉越级路径与坏 JSON', () {
    final String out = sanitizeVideoRemoteDictionaryMediaJson(
      jsonEncode(<Map<String, String>>[
        <String, String>{'dictionary': 'd', 'path': 'img/a.png'},
        <String, String>{'dictionary': 'd', 'path': '../../etc/passwd'},
      ]),
    );
    final List<dynamic> decoded = jsonDecode(out) as List<dynamic>;
    expect(decoded, hasLength(1));
    expect((decoded.single as Map<String, dynamic>)['path'], 'img/a.png');
    expect(sanitizeVideoRemoteDictionaryMediaJson('{oops'), '[]');
    expect(sanitizeVideoRemoteDictionaryMediaJson(''), '');
  });

  group('matchVideoRemoteFavoriteCue', () {
    final List<VideoRemoteCue> rows = videoRemoteTrackRows(
      <AudioCue>[
        _cue(1000, 2000, '一'),
        _cue(3000, 4000, '二'),
        _cue(5000, 6000, '二'),
      ],
      'primary',
      0,
    );

    test('起点 + 文本命中', () {
      expect(
        matchVideoRemoteFavoriteCue(rows, _favorite('二', 3000)).id,
        'primary:1',
      );
    });

    test('文本改过但起点对得上时退回只按起点', () {
      expect(
        matchVideoRemoteFavoriteCue(rows, _favorite('旧文', 1000)).id,
        'primary:0',
      );
    });

    test('无起点且多行同文 → 409 ambiguous；找不到 → 404', () {
      expect(
        () => matchVideoRemoteFavoriteCue(rows, _favorite('二', null)),
        throwsA(_remoteError(409, 'favorite_subtitle_ambiguous')),
      );
      expect(
        () => matchVideoRemoteFavoriteCue(rows, _favorite('无', 9999)),
        throwsA(_remoteError(404, 'favorite_subtitle_missing')),
      );
    });
  });

  test('videoRemotePaddedMiningRange 加首尾留白、不越过相邻句', () {
    final List<AudioCue> cues = <AudioCue>[
      _cue(0, 1000, 'a'),
      _cue(2000, 3000, 'b'),
      _cue(4000, 5000, 'c'),
    ];
    final ({int startMs, int endMs}) r = videoRemotePaddedMiningRange(
      startMs: 2000,
      endMs: 3000,
      cues: cues,
      headPadMs: 200,
      tailPadMs: 200,
    );
    expect(r.startMs, lessThanOrEqualTo(2000));
    expect(r.startMs, greaterThanOrEqualTo(1000));
    expect(r.endMs, greaterThanOrEqualTo(3000));
    expect(r.endMs, lessThanOrEqualTo(4000));
  });

  test('videoRemoteMineSentence：调过上下文用合成句，否则用手机带来的句子', () {
    const VideoRemoteMineSelection adjusted = VideoRemoteMineSelection(
      startMs: 0,
      endMs: 1,
      sentence: '合成',
      cueSentence: '原句',
      adjusted: true,
    );
    const VideoRemoteMineSelection plain = VideoRemoteMineSelection(
      startMs: 0,
      endMs: 1,
      sentence: '原句',
      cueSentence: '原句',
      adjusted: false,
    );
    expect(videoRemoteMineSentence(adjusted, '手机'), '合成');
    expect(videoRemoteMineSentence(plain, '手机'), '手机');
    expect(videoRemoteMineSentence(plain, null), '原句');
  });
}
