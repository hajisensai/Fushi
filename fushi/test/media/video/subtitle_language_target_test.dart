/// 自动挑字幕的目标语言（BUG：外挂字幕恒按日语、内封轨不看语言、繁简不分）。
///
/// 覆盖：目标语言解析（含繁 / 简）、候选匹配档次、同目录外挂排序（含读正文判繁简与
/// 音轨语言兜底）、默认字幕让位、内封 / 远端 / YouTube 轨挑选、字幕文件夹匹配，以及
/// 从库里取证据（合集系列字幕语言 > 全局 > 视频语言 > 刮削原语言）。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_directory_match.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_language_target.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_language_resolver.dart';
import 'package:fushi_engine/media/video/video_sidecar.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoEmbeddedSubtitleTrack;
import 'package:fushi/src/media/video/remote_subtitle_catalog.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const SubtitleLanguageTarget _hant = SubtitleLanguageTarget(
  'zh',
  script: ChineseScript.traditional,
);
const SubtitleLanguageTarget _hans = SubtitleLanguageTarget(
  'zh',
  script: ChineseScript.simplified,
);

String? _pick(List<String> names, String lang) =>
    pickSidecar('EP01', <String>['EP01.mkv', ...names], langCode: lang);

void main() {
  group('SubtitleLanguageTarget.parse', () {
    test('基础语言与地区写法归一', () {
      expect(
        SubtitleLanguageTarget.parse('ja-JP'),
        const SubtitleLanguageTarget('ja'),
      );
      expect(
        SubtitleLanguageTarget.parse('jpn'),
        const SubtitleLanguageTarget('ja'),
      );
      expect(
        SubtitleLanguageTarget.parse('ko'),
        const SubtitleLanguageTarget('ko'),
      );
      expect(SubtitleLanguageTarget.parse(''), isNull);
      expect(SubtitleLanguageTarget.parse('und'), isNull);
      expect(SubtitleLanguageTarget.parse(null), isNull);
    });

    test('中文保留繁 / 简；纯 zh 不猜简体', () {
      expect(SubtitleLanguageTarget.parse('zh-Hant'), _hant);
      expect(SubtitleLanguageTarget.parse('zh_TW'), _hant);
      expect(SubtitleLanguageTarget.parse('zh-HK'), _hant);
      expect(SubtitleLanguageTarget.parse('cht'), _hant);
      expect(SubtitleLanguageTarget.parse('yue'), _hant);
      expect(SubtitleLanguageTarget.parse('zh-Hans'), _hans);
      expect(SubtitleLanguageTarget.parse('zh-CN'), _hans);
      expect(SubtitleLanguageTarget.parse('chs'), _hans);
      expect(
        SubtitleLanguageTarget.parse('zh'),
        const SubtitleLanguageTarget('zh'),
      );
      expect(
        SubtitleLanguageTarget.parse('chi'),
        const SubtitleLanguageTarget('zh'),
      );
    });

    test('规范标签可以原样再解析回来', () {
      expect(_hant.tag, 'zh-Hant');
      expect(_hans.tag, 'zh-Hans');
      expect(SubtitleLanguageTarget.parse(_hant.tag), _hant);
    });
  });

  test('chineseScriptOfLabel 认轨标题里的繁 / 简，双语不表态', () {
    expect(chineseScriptOfLabel('繁體中文'), ChineseScript.traditional);
    expect(
      chineseScriptOfLabel('Chinese (Traditional)'),
      ChineseScript.traditional,
    );
    expect(chineseScriptOfLabel('CHT'), ChineseScript.traditional);
    expect(chineseScriptOfLabel('简体中文'), ChineseScript.simplified);
    expect(
      chineseScriptOfLabel('Simplified Chinese'),
      ChineseScript.simplified,
    );
    expect(chineseScriptOfLabel('简繁双语'), isNull);
    expect(chineseScriptOfLabel('Chinese'), isNull);
  });

  test('matchSubtitleTarget 中文分三档', () {
    expect(
      matchSubtitleTarget(_hant, languageTag: 'zh-TW'),
      SubtitleTargetMatch.exact,
    );
    expect(
      matchSubtitleTarget(_hant, languageTag: 'chi', label: '繁體中文'),
      SubtitleTargetMatch.exact,
    );
    expect(
      matchSubtitleTarget(_hant, languageTag: 'chi'),
      SubtitleTargetMatch.scriptUnknown,
    );
    expect(
      matchSubtitleTarget(_hant, languageTag: 'chs'),
      SubtitleTargetMatch.otherScript,
    );
    expect(
      matchSubtitleTarget(
        _hant,
        languageTag: 'chi',
        contentScript: ChineseScript.traditional,
      ),
      SubtitleTargetMatch.exact,
    );
    expect(
      matchSubtitleTarget(
        const SubtitleLanguageTarget('ja'),
        languageTag: 'eng',
      ),
      SubtitleTargetMatch.none,
    );
    expect(
      matchSubtitleTarget(
        const SubtitleLanguageTarget('zh'),
        languageTag: 'chs',
      ),
      SubtitleTargetMatch.exact,
    );
  });

  group('resolveSubtitleLanguageTarget', () {
    test('与下载链同优先级：显式 > 视频语言 > 刮削原语言 > 全局默认', () {
      expect(
        resolveSubtitleLanguageTarget(
          explicitSubtitlePreference: 'ko',
          videoContentLanguage: 'ja',
        ),
        const SubtitleLanguageTarget('ko'),
      );
      expect(
        resolveSubtitleLanguageTarget(
          videoContentLanguage: 'ko',
          contentMetadataLanguage: 'ja',
          globalDefaultContentLanguage: 'en',
        ),
        const SubtitleLanguageTarget('ko'),
      );
      expect(
        resolveSubtitleLanguageTarget(
          contentMetadataLanguage: 'ja',
          globalDefaultContentLanguage: 'en',
        ),
        const SubtitleLanguageTarget('ja'),
      );
      expect(resolveSubtitleLanguageTarget(), isNull);
    });

    test('显式只写 zh 时补上同为中文的内容语言的繁 / 简', () {
      expect(
        resolveSubtitleLanguageTarget(
          explicitSubtitlePreference: 'zh',
          videoContentLanguage: 'zh-Hant',
        ),
        _hant,
      );
      expect(
        resolveSubtitleLanguageTarget(
          explicitSubtitlePreference: 'ja',
          videoContentLanguage: 'zh-Hant',
        ),
        const SubtitleLanguageTarget('ja'),
      );
    });

    test('基础码与下载链逐一一致', () {
      for (final List<String?> c in <List<String?>>[
        <String?>[null, 'zh-Hant', null, null],
        <String?>['ja', 'ko', null, null],
        <String?>[null, null, 'jpn', 'en'],
        <String?>[null, null, null, null],
        <String?>['', '  ', 'ko-KR', null],
      ]) {
        expect(
          resolveSubtitleLanguageTarget(
            explicitSubtitlePreference: c[0],
            videoContentLanguage: c[1],
            contentMetadataLanguage: c[2],
            globalDefaultContentLanguage: c[3],
          )?.code,
          resolveSubtitleDownloadLanguage(
            explicitSubtitlePreference: c[0],
            videoContentLanguage: c[1],
            contentMetadataLanguage: c[2],
            globalDefaultContentLanguage: c[3],
          ),
          reason: '$c',
        );
      }
    });
  });

  group('同目录外挂字幕按目标语言挑', () {
    test('韩剧：.ko.srt 自动加载，不再被日语硬编码挡掉', () {
      expect(
        _pick(<String>['EP01.ko.srt', 'EP01.en.srt'], 'ko'),
        'EP01.ko.srt',
      );
      expect(_pick(<String>['EP01.srt', 'EP01.ko.srt'], 'ko'), 'EP01.ko.srt');
      expect(_pick(<String>['EP01.en.srt'], 'ko'), isNull);
    });

    test('语言标记按语言比而不是按字面', () {
      expect(_pick(<String>['EP01.jpn.ass'], 'ja'), 'EP01.jpn.ass');
      expect(_pick(<String>['EP01.ja-JP.srt'], 'ja'), 'EP01.ja-JP.srt');
      expect(
        _pick(<String>['EP01.japanese.ass', 'EP01.ja.srt'], 'ja'),
        'EP01.ja.srt',
      );
      expect(_pick(<String>['EP01.forced.srt'], 'ja'), isNull);
    });

    test('繁体内容挑繁体字幕，简体内容挑简体字幕', () {
      const List<String> pair = <String>['EP01.chs.ass', 'EP01.cht.ass'];
      expect(_pick(pair, 'zh-Hant'), 'EP01.cht.ass');
      expect(_pick(pair, 'zh-TW'), 'EP01.cht.ass');
      expect(_pick(pair, 'zh-Hans'), 'EP01.chs.ass');
      expect(
        _pick(<String>['EP01.zh-CN.srt', 'EP01.zh-TW.srt'], 'zh-Hant'),
        'EP01.zh-TW.srt',
      );
      expect(
        _pick(<String>['EP01.sc.ass', 'EP01.tc.ass'], 'zh-Hans'),
        'EP01.sc.ass',
      );
    });

    test('只标中文的排在书写系统相反的前面；相反的也比没有强', () {
      expect(
        _pick(<String>['EP01.chs.ass', 'EP01.zh.srt'], 'zh-Hant'),
        'EP01.zh.srt',
      );
      expect(_pick(<String>['EP01.chs.ass'], 'zh-Hant'), 'EP01.chs.ass');
      expect(
        _pick(<String>['EP01.srt', 'EP01.chs.srt'], 'zh-Hant'),
        'EP01.srt',
      );
    });

    test('目标只写了 zh：任一中文都算对上', () {
      expect(
        _pick(<String>['EP01.en.srt', 'EP01.cht.srt'], 'zh'),
        'EP01.cht.srt',
      );
    });

    test('正文判出的繁 / 简参与排序', () {
      expect(
        pickSidecar(
          'EP01',
          <String>['EP01.zh.srt', 'EP01.chi.srt'],
          langCode: 'zh-Hant',
          contentScripts: <String, ChineseScript>{
            'EP01.zh.srt': ChineseScript.simplified,
            'EP01.chi.srt': ChineseScript.traditional,
          },
        ),
        'EP01.chi.srt',
      );
    });

    test('语言未知不猜：无标记优先，同一种语言才用标记版，混着几种就不挑', () {
      expect(_pick(<String>['EP01.ja.srt', 'EP01.srt'], ''), 'EP01.srt');
      expect(_pick(<String>['EP01.ja.srt', 'EP01.jpn.ass'], ''), 'EP01.ja.srt');
      expect(_pick(<String>['EP01.ja.srt', 'EP01.en.srt'], ''), isNull);
      expect(_pick(<String>['EP01.chs.ass', 'EP01.cht.ass'], ''), isNull);
      expect(_pick(<String>['EP01.forced.srt'], ''), isNull);
    });

    test('只在标记分不出繁简时才要读正文', () {
      expect(
        sidecarSubtitlesNeedingScriptSniff('EP01', <String>[
          'EP01.zh.srt',
          'EP01.srt',
          'EP01.chs.srt',
        ], langCode: 'zh-Hant'),
        <String>['EP01.zh.srt', 'EP01.srt'],
      );
      expect(
        sidecarSubtitlesNeedingScriptSniff('EP01', <String>[
          'EP01.zh.srt',
          'EP01.cht.srt',
        ], langCode: 'zh-Hant'),
        isEmpty,
      );
      expect(
        sidecarSubtitlesNeedingScriptSniff('EP01', <String>[
          'EP01.zh.srt',
        ], langCode: 'ja'),
        isEmpty,
      );
    });

    test('字幕菜单把自动加载会选的排在最前', () {
      expect(
        pickSameNameSubs('EP01', <String>[
          'EP01.en.srt',
          'EP01.chs.ass',
          'EP01.cht.ass',
          'EP02.cht.ass',
        ], langCode: 'zh-Hant'),
        <String>['EP01.cht.ass', 'EP01.chs.ass', 'EP01.en.srt'],
      );
    });
  });

  group('默认字幕落盘与让位', () {
    test('后缀用目标语言规范标签', () {
      expect(
        defaultSidecarSubtitleSuffix('srt', langCode: 'zh-TW'),
        '.zh-Hant.srt',
      );
      expect(
        defaultSidecarSubtitleSuffix('.ass', langCode: 'ko-KR'),
        '.ko.ass',
      );
      expect(defaultSidecarSubtitleSuffix('vtt', langCode: ''), '.vtt');
    });

    test('只让位排在它前面的与同名的', () {
      expect(
        sidecarNamesDisplacedBy('EP01', '.ja.ass', <String>[
          'EP01.ja.srt',
          'EP01.srt',
          'EP01.en.srt',
        ], langCode: 'ja'),
        <String>{'ep01.ja.ass', 'ep01.ja.srt'},
      );
      expect(
        sidecarNamesDisplacedBy('EP01', '.zh-Hant.srt', <String>[
          'EP01.cht.srt',
          'EP01.chs.srt',
        ], langCode: 'zh-Hant'),
        <String>{'ep01.zh-hant.srt', 'ep01.cht.srt'},
      );
    });
  });

  group('findSidecarSubtitle（读盘）', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('sub_lang_target'));
    tearDown(() => dir.deleteSync(recursive: true));

    File write(String name, String body) =>
        File(p.join(dir.path, name))..writeAsStringSync(body);

    String srt(String line) =>
        '1\n00:00:01,000 --> 00:00:03,000\n$line\n\n'
        '2\n00:00:04,000 --> 00:00:06,000\n$line\n';

    test('只标中文的两份，读正文挑出繁体', () async {
      final File video = write('EP01.mkv', '');
      write('EP01.zh.srt', srt('这是简体中文的对话，我们说话时会这样写。这里还有国际电视节目。'));
      write('EP01.chi.srt', srt('這是繁體中文的對話，我們說話時會這樣寫。這裡還有國際電視節目。'));
      expect(
        p.basename(
          (await findSidecarSubtitle(video.path, langCode: 'zh-Hant'))!,
        ),
        'EP01.chi.srt',
      );
      expect(
        p.basename(
          (await findSidecarSubtitle(video.path, langCode: 'zh-Hans'))!,
        ),
        'EP01.zh.srt',
      );
    });

    test('语言未知且混着几种语言时才问音轨语言', () async {
      final File video = write('EP01.mkv', '');
      write('EP01.ja.srt', srt('こんにちは'));
      write('EP01.en.srt', srt('hello'));
      int calls = 0;
      final String? picked = await findSidecarSubtitle(
        video.path,
        langCode: '',
        fallbackLanguage: () async {
          calls++;
          return 'ja';
        },
      );
      expect(p.basename(picked!), 'EP01.ja.srt');
      expect(calls, 1);

      write('EP01.srt', srt('untagged'));
      final String? untagged = await findSidecarSubtitle(
        video.path,
        langCode: '',
        fallbackLanguage: () async {
          calls++;
          return 'ja';
        },
      );
      expect(p.basename(untagged!), 'EP01.srt');
      expect(calls, 1, reason: '有无标记的就不必起 ffmpeg 问音轨');
    });
  });

  group('内封 / 远端 / YouTube 轨', () {
    final List<SubtitleSource> embedded = <SubtitleSource>[
      SubtitleSource.embedded(
        streamIndex: 0,
        language: 'eng',
        codec: 'ass',
        label: '内封 0: eng / English / ass',
      ),
      SubtitleSource.embedded(
        streamIndex: 1,
        language: 'chi',
        codec: 'ass',
        label: '内封 1: chi / 简体中文 / ass',
      ),
      SubtitleSource.embedded(
        streamIndex: 2,
        language: 'chi',
        codec: 'ass',
        label: '内封 2: chi / 繁體中文 / ass',
      ),
      SubtitleSource.embedded(
        streamIndex: 3,
        language: 'jpn',
        codec: 'hdmv_pgs_subtitle',
        label: '内封 3: jpn / hdmv_pgs_subtitle',
      ),
    ];

    test('内封轨按目标语言挑，繁简对上优先；图形轨被 accept 过滤', () {
      expect(
        pickSubtitleSourceForTarget(
          embedded,
          _hant,
          accept: isTextEmbeddedSubtitleSource,
        )?.streamIndex,
        2,
      );
      expect(
        pickSubtitleSourceForTarget(
          embedded,
          _hans,
          accept: isTextEmbeddedSubtitleSource,
        )?.streamIndex,
        1,
      );
      expect(
        pickSubtitleSourceForTarget(
          embedded,
          const SubtitleLanguageTarget('ja'),
          accept: isTextEmbeddedSubtitleSource,
        ),
        isNull,
      );
      expect(pickSubtitleSourceForTarget(embedded, null), isNull);
    });

    test('ffmpeg 日志里的音轨语言成为最后一条证据', () {
      const String log =
          '  Stream #0:0: Video: h264\n'
          '  Stream #0:1(jpn): Audio: aac, 48000 Hz\n'
          '  Stream #0:2(und): Audio: aac\n'
          '  Stream #0:3(eng): Subtitle: ass\n';
      expect(parseAudioStreamLanguagesFromFfmpegLog(log), <String>['jpn']);
      expect(
        audioSubtitleLanguageTarget(const <String>['und', 'jpn']),
        const SubtitleLanguageTarget('ja'),
      );
      expect(audioSubtitleLanguageTarget(const <String>[]), isNull);
    });

    test('远端起播：偏好 > 目标语言 > 服务器默认', () {
      const List<RemoteVideoEmbeddedSubtitleTrack> tracks =
          <RemoteVideoEmbeddedSubtitleTrack>[
            RemoteVideoEmbeddedSubtitleTrack(
              streamIndex: 3,
              codec: 'subrip',
              language: 'eng',
              title: 'English',
              isDefault: true,
            ),
            RemoteVideoEmbeddedSubtitleTrack(
              streamIndex: 4,
              codec: 'subrip',
              language: 'chi',
              title: '繁體中文',
            ),
          ];
      expect(
        pickRemoteStartupSubtitleTrack(
          tracks,
          preferences: const <String>[],
          languageTag: 'zh-Hant',
        )?.streamIndex,
        4,
      );
      expect(
        pickRemoteStartupSubtitleTrack(
          tracks,
          preferences: const <String>['eng'],
          languageTag: 'zh-Hant',
        )?.streamIndex,
        3,
      );
      expect(
        pickRemoteStartupSubtitleTrack(
          tracks,
          preferences: const <String>[],
        )?.streamIndex,
        3,
      );
    });

    test('YouTube 字幕按繁简排序', () {
      const List<YoutubeCaptionTrack> tracks = <YoutubeCaptionTrack>[
        YoutubeCaptionTrack(
          isAutoGenerated: false,
          languageCode: 'zh-Hans',
          languageName: '中文（简体）',
          baseUrl: 'https://example.invalid/a',
        ),
        YoutubeCaptionTrack(
          isAutoGenerated: false,
          languageCode: 'zh-TW',
          languageName: '中文（台灣）',
          baseUrl: 'https://example.invalid/b',
        ),
      ];
      expect(
        orderYoutubeCaptionTracks(
          tracks,
          preferLang: 'zh-Hant',
        ).first.languageCode,
        'zh-TW',
      );
      expect(
        orderYoutubeCaptionTracks(
          tracks,
          preferLang: 'zh-Hans',
        ).first.languageCode,
        'zh-Hans',
      );
    });

    test('字幕文件夹：繁体内容不认简体标记', () {
      final SubtitleDirectoryMatch match = matchEpisodeSubtitleInDirectory(
        videoPath: '/v/Show - 01.mkv',
        fileNames: const <String>[
          'Show - 01.chs.ass',
          'Show - 01.cht.ass',
          'Show - 02.chs.ass',
          'Show - 02.cht.ass',
        ],
        langCode: 'zh-Hant',
      );
      expect(match.fileName, 'Show - 01.cht.ass');
    });
  });

  group('从库里取证据', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<VideoBookRow> addVideo(String uid, {String? language}) async {
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(uid),
          title: Value<String>(uid),
          videoPath: Value<String>('/v/$uid.mkv'),
          language: Value<String?>(language),
        ),
      );
      return (await db.getVideoBookByBookUid(uid))!;
    }

    Future<void> addWork({
      int? collectionId,
      String? bookUid,
      required String lang,
    }) => db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion(
        collectionId: Value<int?>(collectionId),
        bookUid: Value<String?>(bookUid),
        mediaType: const Value<String>('tv'),
        title: const Value<String>('Work'),
        originalLanguage: Value<String?>(lang),
        updatedAt: const Value<int>(0),
      ),
    );

    test('合集系列字幕语言压过全局与视频语言；没设才走内容语言链', () async {
      final VideoBookRow ep = await addVideo('video/ep1', language: 'ja');
      final int cid = await db.createMediaCollection('台劇');
      await db.upsertCollectionItemAt(
        cid,
        MediaKind.video.dbValue,
        ep.bookUid,
        0,
      );

      expect(
        await resolveVideoSubtitleLanguageTarget(db, ep),
        const SubtitleLanguageTarget('ja'),
      );
      await db.updateMediaCollectionSubtitleLanguage(cid, 'zh-Hant');
      expect(
        await resolveVideoSubtitleLanguageTarget(
          db,
          ep,
          explicitSubtitlePreference: 'en',
        ),
        _hant,
      );
    });

    test('刮削原语言：本集作品行 > 合集作品行；都没有走全局默认', () async {
      final VideoBookRow lone = await addVideo('video/lone');
      expect(
        await resolveVideoSubtitleLanguageTarget(
          db,
          lone,
          globalDefaultContentLanguage: 'en',
        ),
        const SubtitleLanguageTarget('en'),
      );
      expect(await resolveVideoSubtitleLanguageTarget(db, lone), isNull);

      final VideoBookRow ep = await addVideo('video/kdrama');
      final int cid = await db.createMediaCollection('K');
      await db.upsertCollectionItemAt(
        cid,
        MediaKind.video.dbValue,
        ep.bookUid,
        0,
      );
      await addWork(collectionId: cid, lang: 'ko');
      expect(
        await resolveVideoSubtitleLanguageTarget(db, ep),
        const SubtitleLanguageTarget('ko'),
      );
      await addWork(bookUid: ep.bookUid, lang: 'zh-TW');
      expect(await resolveVideoSubtitleLanguageTarget(db, ep), _hant);
    });

    test('整库读一次与逐个读结论一致；打开时所在合集优先', () async {
      final VideoBookRow ep = await addVideo('video/shared');
      final int a = await db.createMediaCollection('A');
      final int b = await db.createMediaCollection('B');
      for (final int cid in <int>[a, b]) {
        await db.upsertCollectionItemAt(
          cid,
          MediaKind.video.dbValue,
          ep.bookUid,
          0,
        );
      }
      await db.updateMediaCollectionSubtitleLanguage(a, 'ja');
      await db.updateMediaCollectionSubtitleLanguage(b, 'ko');
      final VideoSubtitleLanguageEvidence all =
          await VideoSubtitleLanguageEvidence.load(db);
      expect(all.targetFor(ep), const SubtitleLanguageTarget('ja'));
      expect(
        all.targetFor(ep, preferredCollectionId: b),
        const SubtitleLanguageTarget('ko'),
      );
      expect(
        await resolveVideoSubtitleLanguageTarget(
          db,
          ep,
          preferredCollectionId: b,
        ),
        const SubtitleLanguageTarget('ko'),
      );
    });
  });
}
