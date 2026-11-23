import 'dart:convert';

import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/cast/cast_voice_assignment.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_package.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:test/test.dart';

MangaAudioPackageVolume _volume({
  String id = 'v1',
  String title = '第1巻',
  int pageCount = 3,
  int blocks = 2,
  String content = 'content:abc',
}) => MangaAudioPackageVolume(
  id: id,
  title: title,
  series: 's1',
  pageCount: pageCount,
  blocks: blocks,
  ocr: 'engine:x',
  content: content,
  script: 'volumes/$id/script.json',
  audio: MangaAudioPackagePart(
    manifest: 'volumes/$id/audio/manifest.json',
    lines: 12,
    durationMs: 34567,
    active: true,
  ),
  voices: const <String>['voice-a', 'voice-b'],
  files: const MangaAudioPackageFiles(count: 9, bytes: 1024, sha256: 'ff'),
);

MangaAudioPackageManifest _manifest({List<MangaAudioPackageVolume>? volumes}) =>
    MangaAudioPackageManifest(
      createdAt: 1700000000000,
      app: 'fushi test',
      series: const <MangaAudioPackageSeries>[
        MangaAudioPackageSeries(
          id: 's1',
          title: 'シリーズ',
          members: <String>['v1'],
        ),
      ],
      volumes: volumes ?? <MangaAudioPackageVolume>[_volume()],
    );

Map<String, Object?> _json(MangaAudioPackageManifest m) =>
    jsonDecode(m.encode()) as Map<String, Object?>;

MokuroPayload _payload(List<List<String>> pages, {String? ocr}) =>
    MokuroPayload(
      ocr: ocr == null
          ? null
          : MangaOcrMetadata(
              engine: 'test',
              engineSignature: ocr,
              schemaVersion: 1,
            ),
      images: <MokuroImage>[
        for (int i = 0; i < pages.length; i++)
          MokuroImage(
            url: 'p$i.png',
            size: const MokuroSize(800, 1200),
            blocks: <MokuroBlock>[
              for (final String text in pages[i])
                MokuroBlock(
                  rectangle: const MokuroRect.fromLTWH(10, 10, 100, 200),
                  isVertical: true,
                  fontSize: 20,
                  zIndex: 0,
                  lines: <String>[text],
                ),
            ],
          ),
      ],
    );

String _parseCode(String text) {
  try {
    MangaAudioPackageManifest.parse(text);
  } on MangaAudioPackageFormatException catch (e) {
    return e.code;
  }
  return 'ok';
}

void main() {
  group('包清单', () {
    test('编码后解析回来字段一致', () {
      final MangaAudioPackageManifest parsed = MangaAudioPackageManifest.parse(
        _manifest().encode(),
      );
      expect(parsed.version, kMangaAudioPackageVersion);
      expect(parsed.app, 'fushi test');
      expect(parsed.series.single.members, <String>['v1']);
      final MangaAudioPackageVolume v = parsed.volumes.single;
      expect(v.title, '第1巻');
      expect(v.pageCount, 3);
      expect(v.blocks, 2);
      expect(v.content, 'content:abc');
      expect(v.script, 'volumes/v1/script.json');
      expect(v.audio!.lines, 12);
      expect(v.audio!.durationMs, 34567);
      expect(v.audio!.dir, 'volumes/v1/audio');
      expect(v.activePart, isNotNull);
      expect(v.hasAudio, isTrue);
      expect(v.voices, <String>['voice-a', 'voice-b']);
      expect(v.files.sha256, 'ff');
      expect(parsed.volumeById('v1'), isNotNull);
      expect(parsed.seriesById('s1')!.title, 'シリーズ');
    });

    test('不是有声漫画包 / 版本更新 / 结构坏分别抛对应错误码', () {
      expect(_parseCode('not json'), 'malformed');
      expect(
        _parseCode(jsonEncode(<String, Object?>{'format': 'x'})),
        'not_package',
      );
      final Map<String, Object?> newer = _json(_manifest())
        ..['v'] = kMangaAudioPackageVersion + 1;
      expect(_parseCode(jsonEncode(newer)), 'too_new');
      final Map<String, Object?> empty = _json(_manifest())
        ..['volumes'] = <Object?>[];
      expect(_parseCode(jsonEncode(empty)), 'malformed');
      final Map<String, Object?> dup = _json(
        _manifest(volumes: <MangaAudioPackageVolume>[_volume(), _volume()]),
      );
      expect(_parseCode(jsonEncode(dup)), 'malformed');
    });

    test('卷里的路径越出本卷目录或不安全时整包判坏', () {
      final Map<String, Object?> raw = _json(_manifest());
      final Map<String, Object?> vol =
          (raw['volumes']! as List<Object?>).single! as Map<String, Object?>;
      vol['script'] = 'volumes/v2/script.json';
      expect(_parseCode(jsonEncode(raw)), 'malformed');
      vol['script'] = '../evil.json';
      expect(_parseCode(jsonEncode(raw)), 'malformed');
    });
  });

  test('包内路径安全判定', () {
    expect(isSafeMangaAudioPackagePath('volumes/v1/pages/001.png'), isTrue);
    expect(isSafeMangaAudioPackagePath('/abs'), isFalse);
    expect(isSafeMangaAudioPackagePath('a/../b'), isFalse);
    expect(isSafeMangaAudioPackagePath('a//b'), isFalse);
    expect(isSafeMangaAudioPackagePath(r'a\b'), isFalse);
    expect(isSafeMangaAudioPackagePath('C:/x'), isFalse);
    expect(isSafeMangaAudioPackagePath(''), isFalse);
  });

  test('文件摘要与路径顺序无关、内容一变就变', () {
    final String a = mangaAudioPackageFilesDigest(<String, String>{
      'b': '2',
      'a': '1',
    });
    final String b = mangaAudioPackageFilesDigest(<String, String>{
      'a': '1',
      'b': '2',
    });
    expect(a, b);
    expect(
      mangaAudioPackageFilesDigest(<String, String>{'a': '1', 'b': '3'}),
      isNot(a),
    );
  });

  test('内容签名不受引擎签名影响、只随 OCR 内容变', () {
    final String x = mangaPayloadContentSignature(
      _payload(<List<String>>[
        <String>['あ'],
        <String>['い'],
      ], ocr: 'engine-1'),
    );
    final String y = mangaPayloadContentSignature(
      _payload(<List<String>>[
        <String>['あ'],
        <String>['い'],
      ], ocr: 'engine-2'),
    );
    final String z = mangaPayloadContentSignature(
      _payload(<List<String>>[
        <String>['あ'],
        <String>['う'],
      ], ocr: 'engine-1'),
    );
    expect(x, y);
    expect(z, isNot(x));
  });

  group('卷匹配', () {
    const MangaPackageLocalVolume same = MangaPackageLocalVolume(
      bookKey: 'k-same',
      title: '第1巻',
      pageCount: 3,
      content: 'content:abc',
    );

    test('页数与内容签名一致就是同一卷，多个时取同标题', () {
      final MangaPackageVolumeMatch m = matchMangaAudioPackageVolume(
        _volume(),
        const <MangaPackageLocalVolume>[
          MangaPackageLocalVolume(
            bookKey: 'k-other-title',
            title: '別名',
            pageCount: 3,
            content: 'content:abc',
          ),
          same,
        ],
      );
      expect(m.kind, MangaPackageMatchKind.existing);
      expect(m.bookKey, 'k-same');
    });

    test('同标题但页数 / OCR 不同 → 冲突', () {
      final MangaPackageVolumeMatch pages = matchMangaAudioPackageVolume(
        _volume(pageCount: 4),
        const <MangaPackageLocalVolume>[same],
      );
      expect(pages.kind, MangaPackageMatchKind.conflict);
      expect(pages.conflict, MangaPackageConflict.pageMismatch);
      final MangaPackageVolumeMatch ocr = matchMangaAudioPackageVolume(
        _volume(content: 'content:zzz'),
        const <MangaPackageLocalVolume>[same],
      );
      expect(ocr.kind, MangaPackageMatchKind.conflict);
      expect(ocr.conflict, MangaPackageConflict.ocrMismatch);
      expect(ocr.bookKey, 'k-same');
    });

    test('没有 OCR 块的卷还要标题一致才算同一卷', () {
      final MangaPackageVolumeMatch m = matchMangaAudioPackageVolume(
        _volume(blocks: 0, title: '別の巻'),
        const <MangaPackageLocalVolume>[same],
      );
      expect(m.kind, MangaPackageMatchKind.create);
    });

    test('本机没有 → 新卷', () {
      expect(
        matchMangaAudioPackageVolume(
          _volume(),
          const <MangaPackageLocalVolume>[],
        ).kind,
        MangaPackageMatchKind.create,
      );
    });
  });

  group('系列合并', () {
    test('本机已设的优先，包里只补空缺；用词替换按原文去重', () {
      final SeriesCastProfile local = SeriesCastProfile(
        seriesKey: 'local',
        roster: <String, TtsCastCharacter>{
          '太郎': const TtsCastCharacter(name: '太郎', aliases: <String>['タロウ']),
        },
        voices: CastVoiceAssignment(
          defaultVoice: 'mine-default',
          byCharacter: <String, String>{'太郎': 'mine-taro'},
        ),
        substitutions: <CastTextSubstitution>[
          const CastTextSubstitution(source: '俺', replacement: 'おれ'),
        ],
      );
      final SeriesCastProfile incoming = SeriesCastProfile(
        seriesKey: 'pkg',
        title: 'パッケージ',
        roster: <String, TtsCastCharacter>{
          'タロウ': const TtsCastCharacter(name: 'タロウ'),
          '花子': const TtsCastCharacter(name: '花子'),
        },
        voices: CastVoiceAssignment(
          defaultVoice: 'their-default',
          narrationVoice: 'their-narration',
          byCharacter: <String, String>{
            'タロウ': 'their-taro',
            '花子': 'their-hanako',
          },
          retryVoices: <String>['r1'],
        ),
        substitutions: <CastTextSubstitution>[
          const CastTextSubstitution(source: '俺', replacement: 'オレ'),
          const CastTextSubstitution(source: '僕', replacement: 'ぼく'),
        ],
        defaultSeed: 7,
      );
      mergeImportedSeriesProfile(local, incoming);
      expect(local.voices.defaultVoice, 'mine-default');
      expect(local.voices.narrationVoice, 'their-narration');
      expect(local.voices.byCharacter['太郎'], 'mine-taro');
      expect(local.voices.byCharacter.containsKey('タロウ'), isFalse);
      expect(local.voices.byCharacter['花子'], 'their-hanako');
      expect(local.voices.retryVoices, <String>['r1']);
      expect(local.roster.containsKey('花子'), isTrue);
      expect(
        <String>[
          for (final CastTextSubstitution s in local.substitutions) s.source,
        ],
        <String>['俺', '僕'],
      );
      expect(local.substitutions.first.replacement, 'おれ');
      expect(local.defaultSeed, 7);
      expect(local.title, 'パッケージ');
    });

    test('成员顺序：已在的不动，新卷插在包里前一卷之后', () {
      final List<String> members = <String>['a', 'c'];
      mergeSeriesMemberOrder(members, <String>['a', 'b', 'c', 'd']);
      expect(members, <String>['a', 'b', 'c', 'd']);
      final List<String> other = <String>['x'];
      mergeSeriesMemberOrder(other, <String>['y', 'z']);
      expect(other, <String>['x', 'y', 'z']);
    });
  });
}
