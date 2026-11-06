import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/lrclib_client.dart';
import 'package:fushi/src/media/music/lyrics/lyrics_candidate_scoring.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';

/// BUG：日文歌的 LRCLIB 精确命中是罗马音版（反馈 zl9Nmfldfr：うさぎとかめ 整页罗马音）。
/// 歌词书写系统与曲目元数据对不上时，从 `/api/search` 挑同名同时长的原文版；挑不到就排到
/// 歌词插件之后；改版前缓存的罗马音行重挑一次并保留偏移。LRCLIB 全走离线 fixture。
Future<LyricTimeline> _parse(Uint8List b, String hint, int? d) async =>
    FushiLyrics.parse(b, hint: hint, durationMs: d);

const String _romaji =
    'Moshi moshi kame yo kame-san yo\n'
    'Sekai no uchi ni omae hodo\n'
    'Ayumi no noroi mono wa nai';
const String _japanese =
    'もしもしかめよ かめさんよ\n'
    '世界のうちに お前ほど\n'
    '歩みの のろい ものはない';

Map<String, Object?> _record(
  int id,
  String lyrics, {
  double duration = 165,
  String track = 'うさぎとかめ',
  String artist = '平沢唯(CV:豊崎愛生)',
}) => <String, Object?>{
  'id': id,
  'trackName': track,
  'artistName': artist,
  'albumName': 'TVアニメ「けいおん!!」オリジナル・サウンドトラック Vol.1',
  'duration': duration,
  'instrumental': false,
  'plainLyrics': lyrics,
  'syncedLyrics': null,
};

class _FakeLrclib {
  final List<Uri> calls = <Uri>[];
  Map<String, Object?>? get = _record(1, _romaji);
  List<Map<String, Object?>> search = <Map<String, Object?>>[];
  int searchStatus = 200;

  Future<({int status, String body})> call(Uri uri) async {
    calls.add(uri);
    if (uri.path == '/api/search') {
      return (status: searchStatus, body: jsonEncode(search));
    }
    final Map<String, Object?>? g = get;
    return g == null
        ? (status: 404, body: '')
        : (status: 200, body: jsonEncode(g));
  }

  List<Uri> get searches =>
      calls.where((Uri u) => u.path == '/api/search').toList();
}

class _FakePlugin {
  List<MusicPluginLyricsCandidate> candidates = <MusicPluginLyricsCandidate>[];
  MusicPluginLyrics? lyrics;

  /// 按插件 id 给不同歌词（没登记的 id 回 [lyrics]）。
  Map<String, MusicPluginLyrics> lyricsById = <String, MusicPluginLyrics>{};

  /// 按候选 ref 的 `id` 给不同歌词（优先于 [lyricsById]）。
  Map<String, MusicPluginLyrics> lyricsByRef = <String, MusicPluginLyrics>{};
  final List<String> fetched = <String>[];
  final List<String> fetchedRefs = <String>[];

  Future<List<MusicPluginLyricsCandidate>> search(
    String id,
    String title, {
    String? artist,
    String? album,
    int? durationMs,
    String? query,
  }) async => candidates;

  Future<MusicPluginLyrics?> fetch(String id, Object ref) async {
    fetched.add(id);
    final String refId = '${(ref as Map<String, Object?>)['id']}';
    fetchedRefs.add(refId);
    return lyricsByRef[refId] ?? lyricsById[id] ?? lyrics;
  }
}

MusicPluginLyrics _pluginLyrics(String text) => MusicPluginLyrics(
  original: MusicPluginLyricText(format: 'lrc', text: '[00:01.00]$text'),
);

const MusicPluginLyricsCandidate _pluginHit = MusicPluginLyricsCandidate(
  title: 'うさぎとかめ',
  artist: '平沢唯',
  durationMs: 165000,
  ref: <String, Object?>{'id': 'x'},
);

const String _romajiLine = 'Moshi moshi kame yo kame-san yo sekai no uchi ni';
const String _chineseLine = '世界之中没有比你走得更慢的';

const String _english =
    "I don't wanna be a lazy girl\n"
    'Just let me sleep a little more\n'
    "You say I'm lazy but I'm not\n"
    "Don't say lazy, don't say lazy";
const String _chineseTranslation =
    '我不想做个懒惰的女孩\n'
    '就让我再多睡一会儿\n'
    '你说我懒但我不是';

const LyricsScriptExpectation _ja = LyricsScriptExpectation(
  LyricsScript.kana,
  fromTitle: true,
);
const LyricsScriptExpectation _zh = LyricsScriptExpectation(
  LyricsScript.han,
  fromTitle: true,
);

void main() {
  late FushiDatabase db;
  late _FakeLrclib lrclib;
  late _FakePlugin plugin;
  late int now;

  MusicLyricsService service({
    bool withPlugin = false,
    List<String> providers = const <String>['p'],
  }) => MusicLyricsService(
    database: () => db,
    lrclib: LrclibClient(transport: lrclib.call),
    onlineEnabled: () => true,
    readEmbedded: (String _, int? _) async => <EmbeddedLyrics>[],
    parse: _parse,
    now: () => now,
    pluginSearch: withPlugin ? plugin.search : null,
    pluginFetch: withPlugin ? plugin.fetch : null,
    providers: withPlugin ? () async => providers : null,
  );

  const MusicLyricsTrackRef track = MusicLyricsTrackRef(
    trackUid: 'uid-usagi',
    path: '/nonexistent/うさぎとかめ.flac',
    title: 'うさぎとかめ',
    artist: '平沢唯(CV:豊崎愛生)',
    album: 'TVアニメ「けいおん!!」オリジナル・サウンドトラック Vol.1',
    durationMs: 165000,
  );

  String text(MusicLyricsResolution r) =>
      r.timeline.lines.map((LyricLine l) => l.text).join('\n');

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    lrclib = _FakeLrclib();
    plugin = _FakePlugin();
    now = 100 * const Duration(days: 1).inMilliseconds;
  });

  tearDown(() => db.close());

  group('书写系统判定（纯函数）', () {
    test('假名 / 汉字按字、拉丁字母按词计数，标点 / 数字 / LRC 时间戳不计', () {
      final LyricsScriptProfile p = lyricsScriptProfile(
        "[00:01.00] もしもし亀よ ABC、123 don't stop",
      );
      expect((p.kana, p.han, p.hangul, p.latin), (5, 1, 0, 3));
      expect(lyricsScriptProfile(_romaji).dominant, LyricsScript.latin);
      expect(lyricsScriptProfile(_japanese).dominant, LyricsScript.kana);
      expect(lyricsScriptProfile('사랑해요 너를 정말로').dominant, LyricsScript.hangul);
    });

    test('元数据有假名才期望日文；全拉丁字母不推断（英文歌不误伤）', () {
      expect(expectedLyricsScript(title: 'うさぎとかめ', artist: '平沢唯'), _ja);
      expect(expectedLyricsScript(title: '千本桜', artist: '黒うさP'), _ja);
      expect(expectedLyricsScript(title: '光阴之外', artist: '小时姑娘'), _zh);
      expect(
        expectedLyricsScript(title: 'Yesterday', artist: 'The Beatles'),
        isNull,
      );
    });

    test('标题是拉丁字母、只有艺人 / 专辑带汉字假名：弱推断，英文正文不算对不上', () {
      // 审查：『桜高軽音部 - Don't say "lazy"』、中文歌手的英文歌，原文就是英文。
      final LyricsScriptExpectation? lazy = expectedLyricsScript(
        title: 'Don\'t say "lazy"',
        artist: '桜高軽音部',
        album: 'けいおん! ED',
      );
      expect(
        lazy,
        const LyricsScriptExpectation(LyricsScript.kana, fromTitle: false),
      );
      expect(lyricsScriptMismatches(lazy, _english), isFalse);
      final LyricsScriptExpectation? zhSinger = expectedLyricsScript(
        title: 'Lonely Night',
        artist: '周杰伦',
      );
      expect(
        zhSinger,
        const LyricsScriptExpectation(LyricsScript.han, fromTitle: false),
      );
      expect(lyricsScriptMismatches(zhSinger, _english), isFalse);
      // 标题里的汉字只在括注里时同样算拉丁字母标题。
      expect(
        expectedLyricsScript(
          title: 'Lonely Night (周杰伦版)',
          artist: 'X',
        )!.fromTitle,
        isFalse,
      );
      // 弱推断仍认得罗马音 / 拼音（米津玄師『Lemon』拿到罗马音版）。
      expect(lyricsScriptMismatches(zhSinger, _romaji), isTrue);
      expect(lyricsScriptMismatches(lazy, _romaji), isTrue);
      // 强推断（标题本身是日文）英文翻译照样算对不上。
      expect(lyricsScriptMismatches(_ja, _english), isTrue);
    });

    test('lyricsLooksRomanized：罗马音 / 拼音是，英文不是', () {
      expect(lyricsLooksRomanized(_romaji), isTrue);
      expect(
        lyricsLooksRomanized(
          'Yume naraba dore hodo yokatta deshou\n'
          'Imada ni anata no koto wo yume ni miru',
        ),
        isTrue,
      );
      expect(lyricsLooksRomanized(_english), isFalse);
      expect(
        lyricsLooksRomanized(
          'Yesterday all my troubles seemed so far away\n'
          'Now it looks as though they are here to stay',
        ),
        isFalse,
      );
      expect(lyricsLooksRomanized('Moshi moshi'), isFalse, reason: '词太少不下结论');
    });

    test('期望日文时罗马音 / 中文翻译算对不上，夹英文副歌的原文不算', () {
      expect(lyricsScriptMismatches(_ja, _romaji), isTrue);
      expect(lyricsScriptMismatches(_ja, '世界之中没有比你走得更慢的'), isTrue);
      expect(
        lyricsScriptMismatches(
          _ja,
          "$_japanese\nOh yeah baby tonight\nDon't stop the music",
        ),
        isFalse,
      );
      expect(lyricsScriptMismatches(null, _romaji), isFalse);
      expect(lyricsScriptMismatches(_ja, 'La la'), isFalse);
    });

    test('原文本身夹大量英文的日文 / 中文歌不算对不上（拉丁字母不按字母数高估）', () {
      // 审查给的例子：1 行日文（9 字）配 2 行英文（46 个字母、9 个词），按字母只有 9/55。
      const String jaEn =
          'もしもしかめよかめさん\n'
          'Running through the night with you\n'
          'Never gonna let you go tonight';
      expect(lyricsScriptMismatches(_ja, jaEn), isFalse);
      const String zhEn =
          '我们一起走过的路\n'
          'Baby I just wanna hold you tight\n'
          'Every single day and every night';
      expect(lyricsScriptMismatches(_zh, zhEn), isFalse);
      // 整首罗马音只夹一行假名标题，仍是罗马音版。
      expect(
        lyricsScriptMismatches(_ja, 'うさぎとかめ\n$_romaji\n$_romaji\n$_romaji'),
        isTrue,
      );
    });

    test('pickBestLyricsCandidate：同名同艺人时书写系统对得上的胜出，可要求必须对得上', () {
      LyricsCandidate c(String id, String lyrics, int ms) => LyricsCandidate(
        providerId: 't',
        title: 'うさぎとかめ',
        artist: '平沢唯',
        durationMs: ms,
        ref: <String, String>{'id': id},
        lyricsText: lyrics,
      );
      final List<LyricsCandidate> hits = <LyricsCandidate>[
        c('romaji', _romaji, 165000),
        c('ja', _japanese, 166000),
      ];
      expect(
        pickBestLyricsCandidate(
          hits,
          title: 'うさぎとかめ',
          artist: '平沢唯',
          durationMs: 165000,
          expectedScript: LyricsScript.kana,
        )!.ref['id'],
        'ja',
      );
      expect(
        pickBestLyricsCandidate(
          <LyricsCandidate>[c('romaji', _romaji, 165000)],
          title: 'うさぎとかめ',
          artist: '平沢唯',
          expectedScript: LyricsScript.kana,
          requireScriptMatch: true,
        ),
        isNull,
      );
      // 不给期望文字时行为不变：时长近的胜出。
      expect(
        pickBestLyricsCandidate(
          hits,
          title: 'うさぎとかめ',
          artist: '平沢唯',
          durationMs: 165000,
        )!.ref['id'],
        'romaji',
      );
    });
  });

  test('精确命中是罗马音：改从 /api/search 挑同名的原文版并落库', () async {
    lrclib.search = <Map<String, Object?>>[
      _record(2, _romaji),
      _record(3, _japanese),
      _record(4, '$_japanese\n別録音', duration: 170), // 时长差 5 s：不是同一录音
    ];
    final MusicLyricsResolution r = (await service().resolve(track))!;
    expect(r.source, MusicLyricsSource.lrclib);
    expect(text(r), _japanese);
    final MusicLyricRow row = (await db.select(db.musicLyrics).get()).single;
    expect(utf8.decode(row.raw), _japanese);
    expect(lrclib.searches.first.queryParameters['q'], 'うさぎとかめ 平沢唯');
  });

  test('多条原文候选时长差小者胜出', () async {
    lrclib.search = <Map<String, Object?>>[
      _record(5, '$_japanese\nA', duration: 166.5),
      _record(6, '$_japanese\nB', duration: 165.4),
    ];
    final MusicLyricsResolution r = (await service().resolve(track))!;
    expect(r.timeline.lines.last.text, 'B');
  });

  test('拉丁字母曲目照常采用拉丁字母歌词，不额外搜索（不回归）', () async {
    lrclib.get = _record(
      7,
      'Yesterday all my troubles seemed so far away',
      track: 'Yesterday',
      artist: 'The Beatles',
      duration: 125,
    );
    const MusicLyricsTrackRef en = MusicLyricsTrackRef(
      trackUid: 'uid-en',
      path: '/nonexistent/Yesterday.flac',
      title: 'Yesterday',
      artist: 'The Beatles',
      durationMs: 125000,
    );
    final MusicLyricsResolution r = (await service().resolve(en))!;
    expect(r.source, MusicLyricsSource.lrclib);
    expect(text(r), 'Yesterday all my troubles seemed so far away');
    expect(lrclib.searches, isEmpty);
  });

  test('搜不到原文版：罗马音排到歌词插件之后，插件有原文就用插件', () async {
    lrclib.search = <Map<String, Object?>>[_record(8, _romaji)];
    plugin.candidates = <MusicPluginLyricsCandidate>[
      const MusicPluginLyricsCandidate(
        title: 'うさぎとかめ',
        artist: '平沢唯',
        durationMs: 165000,
        ref: <String, Object?>{'id': 'x'},
      ),
    ];
    plugin.lyrics = const MusicPluginLyrics(
      original: MusicPluginLyricText(
        format: 'lrc',
        text: '[00:01.00]もしもしかめよ かめさんよ',
      ),
    );
    final MusicLyricsResolution r = (await service(
      withPlugin: true,
    ).resolve(track))!;
    expect(r.source, MusicLyricsSource.lyricsPlugin('p'));
    expect(text(r), 'もしもしかめよ かめさんよ');
  });

  test('搜不到原文版、也没有插件：仍用罗马音（不丢歌词），TTL 内不再重挑', () async {
    lrclib.search = <Map<String, Object?>>[_record(8, _romaji)];
    final MusicLyricsResolution r = (await service().resolve(track))!;
    expect(r.source, MusicLyricsSource.lrclib);
    expect(text(r), _romaji);
    final int calls = lrclib.calls.length;
    now += const Duration(days: 1).inMilliseconds;
    await service().resolve(track);
    expect(lrclib.calls.length, calls, reason: '缓存行 TTL 内不重挑');
  });

  test('插件拿到的也是罗马音 / 只有中文翻译：照样只当兜底，下一个插件有原文就用它', () async {
    lrclib.search = <Map<String, Object?>>[_record(8, _romaji)];
    plugin.candidates = <MusicPluginLyricsCandidate>[_pluginHit];
    plugin.lyricsById = <String, MusicPluginLyrics>{
      'romaji': _pluginLyrics(_romajiLine),
      'zh': _pluginLyrics(_chineseLine),
      'ja': _pluginLyrics('もしもしかめよ かめさんよ'),
    };
    final MusicLyricsResolution r = (await service(
      withPlugin: true,
      providers: <String>['romaji', 'zh', 'ja'],
    ).resolve(track))!;
    expect(r.source, MusicLyricsSource.lyricsPlugin('ja'));
    expect(text(r), 'もしもしかめよ かめさんよ');
    expect(plugin.fetched, <String>['romaji', 'zh', 'ja']);
    // 第二次全走缓存：对不上的插件缓存行同样跳过，不会挡住后面的原文版。
    plugin.fetched.clear();
    final MusicLyricsResolution again = (await service(
      withPlugin: true,
      providers: <String>['romaji', 'zh', 'ja'],
    ).resolve(track))!;
    expect(again.source, MusicLyricsSource.lyricsPlugin('ja'));
    expect(plugin.fetched, isEmpty);
  });

  test('LRCLIB 与插件都只有对不上的版本：按来源顺序兜底（LRCLIB 在前）', () async {
    lrclib.search = <Map<String, Object?>>[_record(8, _romaji)];
    plugin.candidates = <MusicPluginLyricsCandidate>[_pluginHit];
    plugin.lyrics = _pluginLyrics(_chineseLine);
    final MusicLyricsResolution r = (await service(
      withPlugin: true,
    ).resolve(track))!;
    expect(r.source, MusicLyricsSource.lrclib);
    expect(text(r), _romaji);
  });

  test('LRCLIB 没有、插件只有对不上的版本：仍用插件那份（不丢歌词）', () async {
    lrclib.get = null;
    plugin.candidates = <MusicPluginLyricsCandidate>[_pluginHit];
    plugin.lyrics = _pluginLyrics(_chineseLine);
    final MusicLyricsResolution r = (await service(
      withPlugin: true,
    ).resolve(track))!;
    expect(r.source, MusicLyricsSource.lyricsPlugin('p'));
    expect(text(r), _chineseLine);
  });

  test('搜索联网失败：这次先用罗马音（不落库），下次重查', () async {
    lrclib.searchStatus = 503;
    final MusicLyricsResolution r = (await service().resolve(track))!;
    expect(text(r), _romaji);
    expect(await db.select(db.musicLyrics).get(), isEmpty);
  });

  test('改版前缓存的罗马音行：重挑一次换成原文版，保留用户调过的偏移', () async {
    await db
        .into(db.musicLyrics)
        .insert(
          MusicLyricsCompanion.insert(
            trackUid: track.trackUid,
            source: MusicLyricsSource.lrclib,
            format: 'txt',
            raw: utf8.encode(_romaji),
            offsetMs: const Value<int>(300),
            updatedAt: now - const Duration(days: 30).inMilliseconds,
          ),
        );
    lrclib.search = <Map<String, Object?>>[_record(3, _japanese)];
    final MusicLyricsResolution r = (await service().resolve(track))!;
    expect(text(r), _japanese);
    expect(r.timeline.offsetMs, 300);
    final MusicLyricRow row = (await db.select(db.musicLyrics).get()).single;
    expect(utf8.decode(row.raw), _japanese);
    expect(row.offsetMs, 300);
    expect(lrclib.calls.where((Uri u) => u.path == '/api/get'), isEmpty);
    final int calls = lrclib.calls.length;
    await service().resolve(track);
    expect(lrclib.calls.length, calls, reason: '换成原文后直接读缓存');
  });

  test('TTL 内落库的旧罗马音行：到期前不重挑（排在插件之后兜底），到期后重挑', () async {
    await db
        .into(db.musicLyrics)
        .insert(
          MusicLyricsCompanion.insert(
            trackUid: track.trackUid,
            source: MusicLyricsSource.lrclib,
            format: 'txt',
            raw: utf8.encode(_romaji),
            updatedAt: now - const Duration(days: 1).inMilliseconds,
          ),
        );
    lrclib.search = <Map<String, Object?>>[_record(3, _japanese)];
    final MusicLyricsResolution r = (await service().resolve(track))!;
    expect(text(r), _romaji);
    expect(lrclib.calls, isEmpty, reason: 'TTL 内不联网重挑');
    now += kLrclibNegativeCacheTtl.inMilliseconds;
    final MusicLyricsResolution later = (await service().resolve(track))!;
    expect(text(later), _japanese);
    expect(lrclib.searches, isNotEmpty);
  });

  test('在线搜索候选：原文版排前，候选标出书写系统', () async {
    lrclib.search = <Map<String, Object?>>[
      _record(2, _romaji),
      _record(3, _japanese),
    ];
    final List<MusicLyricsCandidate> c = await service().searchOnline(track);
    expect(c.map((MusicLyricsCandidate x) => x.script), <LyricsScript?>[
      LyricsScript.kana,
      LyricsScript.latin,
    ]);
  });

  test('拉丁字母标题 + 汉字艺人的英文歌：英文精确命中照常采用，不换成翻译版', () async {
    const MusicLyricsTrackRef lazyTrack = MusicLyricsTrackRef(
      trackUid: 'uid-lazy',
      path: '/nonexistent/lazy.flac',
      title: 'Don\'t say "lazy"',
      artist: '桜高軽音部',
      album: 'TVアニメ「けいおん!」ED',
      durationMs: 165000,
    );
    lrclib.get = _record(
      30,
      _english,
      track: 'Don\'t say "lazy"',
      artist: '桜高軽音部',
    );
    lrclib.search = <Map<String, Object?>>[
      _record(
        31,
        _chineseTranslation,
        track: 'Don\'t say "lazy"',
        artist: '桜高軽音部',
      ),
    ];
    final MusicLyricsResolution r = (await service().resolve(lazyTrack))!;
    expect(r.source, MusicLyricsSource.lrclib);
    expect(text(r), _english);
    expect(lrclib.searches, isEmpty, reason: '英文原文不算对不上，不去搜翻译版');
  });

  test('插件同名候选里先给罗马音：同一插件接着取下一条，挑到原文版', () async {
    lrclib.get = null;
    plugin.candidates = <MusicPluginLyricsCandidate>[
      const MusicPluginLyricsCandidate(
        title: 'うさぎとかめ',
        artist: '平沢唯',
        durationMs: 165000,
        ref: <String, Object?>{'id': 'romaji'},
      ),
      const MusicPluginLyricsCandidate(
        title: 'うさぎとかめ',
        artist: '平沢唯',
        durationMs: 165000,
        ref: <String, Object?>{'id': 'ja'},
      ),
    ];
    plugin.lyricsByRef = <String, MusicPluginLyrics>{
      'romaji': _pluginLyrics(_romajiLine),
      'ja': _pluginLyrics('もしもしかめよ かめさんよ'),
    };
    final MusicLyricsResolution r = (await service(
      withPlugin: true,
    ).resolve(track))!;
    expect(r.source, MusicLyricsSource.lyricsPlugin('p'));
    expect(text(r), 'もしもしかめよ かめさんよ');
    expect(plugin.fetchedRefs, <String>['romaji', 'ja']);
  });

  test('插件缓存的罗马音行：TTL 内兜底，到期后重挑换成原文版并保留偏移', () async {
    lrclib.get = null;
    plugin.candidates = <MusicPluginLyricsCandidate>[_pluginHit];
    plugin.lyrics = _pluginLyrics(_romajiLine);
    final MusicLyricsResolution first = (await service(
      withPlugin: true,
    ).resolve(track))!;
    expect(text(first), _romajiLine);
    await (db.update(db.musicLyrics)..where(
          ($MusicLyricsTable r) =>
              r.source.equals(MusicLyricsSource.lyricsPlugin('p')),
        ))
        .write(const MusicLyricsCompanion(offsetMs: Value<int>(250)));
    // 插件那边换成了原文版。
    plugin.lyrics = _pluginLyrics('もしもしかめよ かめさんよ');
    plugin.fetched.clear();
    final MusicLyricsResolution within = (await service(
      withPlugin: true,
    ).resolve(track))!;
    expect(text(within), _romajiLine, reason: 'TTL 内不重挑');
    expect(plugin.fetched, isEmpty);
    now += kPluginLyricsNegativeCacheTtl.inMilliseconds + 1;
    final MusicLyricsResolution after = (await service(
      withPlugin: true,
    ).resolve(track))!;
    expect(text(after), 'もしもしかめよ かめさんよ');
    expect(after.timeline.offsetMs, 250);
  });

  test('插件缓存的罗马音行重挑仍是罗马音：旧行兜底，TTL 内不再重挑', () async {
    lrclib.get = null;
    plugin.candidates = <MusicPluginLyricsCandidate>[_pluginHit];
    plugin.lyrics = _pluginLyrics(_romajiLine);
    await service(withPlugin: true).resolve(track);
    now += kPluginLyricsNegativeCacheTtl.inMilliseconds + 1;
    plugin.fetched.clear();
    final MusicLyricsResolution again = (await service(
      withPlugin: true,
    ).resolve(track))!;
    expect(text(again), _romajiLine);
    expect(plugin.fetched, <String>['p']);
    plugin.fetched.clear();
    await service(withPlugin: true).resolve(track);
    expect(plugin.fetched, isEmpty);
  });
}
