import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;
import 'package:fushi_engine/media/video/youtube_source_resolver.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;

void main() {
  group('isYoutubeUrl', () {
    test('accepts watch and youtu.be', () {
      expect(isYoutubeUrl('https://www.youtube.com/watch?v=abc123'), true);
      expect(isYoutubeUrl('https://youtu.be/abc123'), true);
    });
    test('rejects non-youtube', () {
      expect(isYoutubeUrl('https://www.netflix.com/watch/1'), false);
      expect(isYoutubeUrl('/local/file.mp4'), false);
    });
    test('matches on domain boundaries, not bare suffixes', () {
      expect(isYoutubeUrl('https://youtube.com/watch?v=abc123'), true);
      expect(isYoutubeUrl('https://m.youtube.com/watch?v=abc123'), true);
      expect(isYoutubeUrl('https://www.youtube-nocookie.com/embed/x'), true);
      expect(isYoutubeUrl('https://notyoutube.com/watch?v=abc123'), false);
      expect(isYoutubeUrl('https://evil-youtube-nocookie.com/embed/x'), false);
    });
  });

  group('parseYoutubeTimedTextToCues', () {
    test('converts timedtext XML to cues with ms bounds', () {
      const xml =
          '<transcript>'
          '<text start="1.5" dur="2.0">走り出した</text>'
          '<text start="4.0" dur="1.5">こんにちは</text>'
          '</transcript>';
      final cues = parseYoutubeTimedTextToCues(content: xml, bookKey: 'yt:abc');
      expect(cues.length, 2);
      expect(cues[0].text, '走り出した');
      expect(cues[0].startMs, 1500);
      expect(cues[0].endMs, 3500);
      expect(cues[1].startMs, 4000);
      expect(cues[1].endMs, 5500);
    });
    test('decodes entities and skips empty', () {
      const xml =
          '<transcript><text start="0" dur="1">&#39;</text><text start="1" dur="1"></text></transcript>';
      final cues = parseYoutubeTimedTextToCues(content: xml, bookKey: 'yt:x');
      expect(cues.length, 1);
      expect(cues[0].text, "'");
    });
  });

  // BUG-4220：真实 timedtext XML 是双重转义的（2026-11-06 抓 dQw4w9WgXcQ 的 en 轨：
  // `We&amp;#39;re`）。只解一层时内置播放器显示 `We&#39;re`；扩展走 json3 不受影响。
  group('parseYoutubeTimedTextToCues double-escaped entities (BUG-4220)', () {
    test('format 3 <p>: &amp;#39; → apostrophe', () {
      const xml =
          '<?xml version="1.0" encoding="utf-8" ?><timedtext format="3"><body>'
          '<p t="18640" d="3240">♪ We&amp;#39;re no strangers to love ♪</p>'
          '<p t="22000" d="3000">and that&amp;#39;s cool &amp;amp; &amp;quot;fine&amp;quot;</p>'
          '</body></timedtext>';
      final cues = parseYoutubeTimedTextToCues(content: xml, bookKey: 'yt:x');
      expect(cues.map((c) => c.text).toList(), <String>[
        "♪ We're no strangers to love ♪",
        "and that's cool & \"fine\"",
      ]);
    });
    test('format 3 ASR <s> segments are decoded after joining', () {
      const xml =
          '<timedtext format="3"><body><p t="0" d="900">'
          '<s ac="0">We&amp;#39;re</s><s t="239" ac="0"> here</s></p></body></timedtext>';
      final cues = parseYoutubeTimedTextToCues(content: xml, bookKey: 'yt:x');
      expect(cues.single.text, "We're here");
    });
    test('srv1 <text>: double-escaped decoded, literal entity text kept', () {
      const xml =
          '<transcript><text start="0" dur="1">it&amp;#39;s</text>'
          '<text start="1" dur="1">&amp;amp;amp; stays</text></transcript>';
      final cues = parseYoutubeTimedTextToCues(content: xml, bookKey: 'yt:x');
      expect(cues[0].text, "it's");
      // 字幕作者真写的 `&amp;`（三层转义）只解两层，原样留下字面文本。
      expect(cues[1].text, '&amp; stays');
    });
  });

  // json3（cueDownloadUrl 请求的主格式，与浏览器扩展同一格式）：`segs[].utf8` 是字幕原文，
  // 无实体转义。fixtures 按 YouTube json3 真实结构写（wireMagic/pens/窗口定义事件/逐词 seg/
  // aAppend 换行事件），对应上面 XML 用例的同一批行（dQw4w9WgXcQ 人工轨 + en ASR 轨）。
  group('parseYoutubeTimedTextToCues json3', () {
    test('manual track: utf8 原文直用，作者写的 <i> / &amp; 不被改写', () {
      const String json = r'''
{"wireMagic":"pb3","pens":[{}],"wsWinStyles":[{}],"wpWinPositions":[{}],"events":[
{"tStartMs":1360,"dDurationMs":1680,"segs":[{"utf8":"[♪♪♪]"}]},
{"tStartMs":18640,"dDurationMs":3240,"segs":[{"utf8":"♪ We're no strangers to love ♪"}]},
{"tStartMs":22000,"dDurationMs":3000,"segs":[{"utf8":"<i>you</i> know &amp; \"rules\""}]}
]}''';
      final List<AudioCue> cues = parseYoutubeTimedTextToCues(
        content: json,
        bookKey: 'yt:abc',
      );
      expect(cues.map((AudioCue c) => c.text).toList(), <String>[
        '[♪♪♪]',
        "♪ We're no strangers to love ♪",
        '<i>you</i> know &amp; "rules"',
      ]);
      expect(cues[0].startMs, 1360);
      expect(cues[0].endMs, 3040);
      expect(cues[2].startMs, 22000);
      expect(cues[2].endMs, 25000);
      expect(cues.map((AudioCue c) => c.sentenceIndex).toList(), <int>[
        0,
        1,
        2,
      ]);
      expect(cues[1].bookKey, 'yt:abc');
      expect(cues[1].chapterHref, 'youtube://yt:abc');
      expect(cues[1].textFragmentId, 'yt-1');
    });

    test('ASR track: 逐词 seg 拼成整行，跳窗口定义事件与 aAppend 换行事件', () {
      const String json = r'''
{"wireMagic":"pb3","pens":[{}],"wsWinStyles":[{},{"mhModeHint":2,"juJustifCode":0,"sdScrollDir":3}],
"wpWinPositions":[{},{"apPoint":6,"ahHorPos":20,"avVerPos":100,"rcRows":2,"ccCols":40}],"events":[
{"tStartMs":0,"dDurationMs":214310,"id":1,"wpWinPosId":1,"wsWinStyleId":1},
{"tStartMs":18800,"dDurationMs":7160,"wWinId":1,"segs":[{"utf8":"We're","acAsrConf":0},{"utf8":" no","tOffsetMs":239,"acAsrConf":0},{"utf8":" strangers","tOffsetMs":559,"acAsrConf":0},{"utf8":" to","tOffsetMs":1040,"acAsrConf":0}]},
{"tStartMs":21790,"dDurationMs":4170,"wWinId":1,"aAppend":1,"segs":[{"utf8":"\n"}]},
{"tStartMs":21800,"dDurationMs":6640,"wWinId":1,"segs":[{"utf8":"love","acAsrConf":0},{"utf8":" you","tOffsetMs":400,"acAsrConf":0},{"utf8":" know","tOffsetMs":800,"acAsrConf":0}]}
]}''';
      final List<AudioCue> cues = parseYoutubeTimedTextToCues(
        content: json,
        bookKey: 'yt:asr',
      );
      expect(cues.map((AudioCue c) => c.text).toList(), <String>[
        "We're no strangers to",
        'love you know',
      ]);
      // json3 只负责如实给出每行时间；滚动双行的前后重叠留给轨级收尾截断。
      expect(cues[0].startMs, 18800);
      expect(cues[0].endMs, 25960);
      expect(cues[1].startMs, 21800);
      expect(cues[1].endMs, 28440);
    });

    test('缺 dDurationMs：以下一事件起点为终点，末尾兜底 1500ms', () {
      const String json = '''
  {"events":[
  {"tStartMs":1000,"segs":[{"utf8":"a"}]},
  {"tStartMs":1000,"segs":[{"utf8":"b"}]},
  {"tStartMs":4000,"segs":[{"utf8":"c"}]},
  {"tStartMs":9000,"dDurationMs":0,"segs":[{"utf8":"d"}]}
  ]}''';
      final List<AudioCue> cues = parseYoutubeTimedTextToCues(
        content: json,
        bookKey: 'yt:x',
      );
      expect(
        cues.map((AudioCue c) => '${c.text}:${c.startMs}-${c.endMs}').toList(),
        <String>['a:1000-1001', 'b:1000-4000', 'c:4000-9000', 'd:9000-10500'],
      );
    });

    test('无 tStartMs / 无 segs / 空文本的事件跳过；无 events 回空', () {
      const String json =
          '{"events":[{"segs":[{"utf8":"no start"}]},'
          '{"tStartMs":10,"dDurationMs":5},'
          '{"tStartMs":20,"dDurationMs":5,"segs":[{"utf8":"  "},{}]},'
          '{"tStartMs":30,"dDurationMs":5,"segs":[{"utf8":"kept"}]}]}';
      final List<AudioCue> cues = parseYoutubeTimedTextToCues(
        content: json,
        bookKey: 'yt:x',
      );
      expect(cues.single.text, 'kept');
      expect(cues.single.sentenceIndex, 0);
      expect(
        parseYoutubeTimedTextToCues(
          content: '{"wireMagic":"pb3"}',
          bookKey: 'yt:x',
        ),
        isEmpty,
      );
    });

    test('请求 json3 却回 XML（YouTube 无视 fmt）：按内容回退 XML 解析', () {
      const String xml =
          '<?xml version="1.0" encoding="utf-8" ?><timedtext format="3"><body>'
          '<p t="18640" d="3240">We&amp;#39;re here</p></body></timedtext>';
      final List<AudioCue> cues = parseYoutubeTimedTextToCues(
        content: xml,
        bookKey: 'yt:x',
      );
      expect(cues.single.text, "We're here");
      expect(cues.single.endMs, 21880);
    });

    test('json3 体损坏抛 FormatException（下载层当失败处理）', () {
      expect(
        () => parseYoutubeTimedTextToCues(content: '{"events":[', bookKey: 'x'),
        throwsFormatException,
      );
    });
  });

  // BUG-783：YouTube androidVr 现在一律返回 timedtext format="3" 的 <p t d>（毫秒），
  // 即使 fmt=srv1 也被无视；旧解析器只认 srv1 <text start dur>（秒）→ 0 cue → 字幕失效。
  // fixtures 用探测抓下来的真实结构（人工轨 <p>text</p>、ASR 轨 <p><s>词</s></p>）。
  group('parseYoutubeTimedTextToCues format 3 (BUG-783)', () {
    test('manual track: <p t d>text</p> 毫秒直用', () {
      const xml =
          '<?xml version="1.0" encoding="utf-8" ?>'
          '<timedtext format="3">\n<body>\n'
          '<p t="1360" d="1680">[♪♪♪]</p>\n'
          '<p t="18640" d="3240">♪ We&#39;re no strangers to love ♪</p>\n'
          '</body>\n</timedtext>';
      final cues = parseYoutubeTimedTextToCues(content: xml, bookKey: 'yt:abc');
      expect(cues.length, 2);
      expect(cues[0].text, '[♪♪♪]');
      expect(cues[0].startMs, 1360);
      expect(cues[0].endMs, 3040); // 1360 + 1680
      expect(cues[1].text, "♪ We're no strangers to love ♪");
      expect(cues[1].startMs, 18640);
      expect(cues[1].endMs, 21880); // 18640 + 3240
    });

    test('ASR track: 拼接 <s> 词级片段、跳空白滚动占位与 <w> 元素', () {
      const xml =
          '<?xml version="1.0" encoding="utf-8" ?>'
          '<timedtext format="3">\n'
          '<head>\n<ws id="0"/>\n<wp id="0"/>\n</head>\n<body>\n'
          '<w t="0" id="1" wp="1" ws="1"/>\n'
          '<p t="320" d="14260" w="1">[Music]</p>\n'
          '<p t="18790" w="1" a="1"> </p>\n'
          '<p t="18800" d="7160" w="1">'
          '<s ac="0">We&#39;re</s><s t="239" ac="0"> no</s>'
          '<s t="559" ac="0"> strangers</s><s t="1040" ac="0"> to</s></p>\n'
          '</body>\n</timedtext>';
      final cues = parseYoutubeTimedTextToCues(content: xml, bookKey: 'yt:asr');
      expect(cues.length, 2); // [Music] + 拼接行；空白 <p a="1"> 与 <w> 跳过
      expect(cues[0].text, '[Music]');
      expect(cues[0].startMs, 320);
      expect(cues[0].endMs, 14580);
      expect(cues[1].text, "We're no strangers to");
      expect(cues[1].startMs, 18800);
      expect(cues[1].endMs, 25960); // 18800 + 7160
    });

    test('format 3 无 d 属性时 endMs 退回 startMs（不崩）', () {
      const xml =
          '<timedtext format="3"><body>'
          '<p t="5000">末尾无时长</p>'
          '</body></timedtext>';
      final cues = parseYoutubeTimedTextToCues(content: xml, bookKey: 'yt:z');
      expect(cues.length, 1);
      expect(cues[0].startMs, 5000);
      expect(cues[0].endMs, 5000);
    });
  });

  // A（浏览器扩展→server 抓 YouTube 真字幕）：server 端点把抓到的轨 + cue 序列化成
  // 扩展可消费的 JSON。纯函数守卫其形状（扩展面板 cue 形状 {text,startMs,endMs}）。
  group('serializeYoutubeCaptionTracks (extension bridge)', () {
    YoutubeCaptionTrack track(String code, String name, bool auto) =>
        YoutubeCaptionTrack(
          baseUrl: 'https://x/timedtext?lang=$code',
          languageCode: code,
          languageName: name,
          isAutoGenerated: auto,
        );
    AudioCue cue(String text, int s, int e) => AudioCue()
      ..text = text
      ..startMs = s
      ..endMs = e;

    test('序列化轨元数据 + cue 三字段', () {
      final json = serializeYoutubeCaptionTracks(
        <YoutubeCaptionTrack>[track('ja', '日本語', false)],
        <List<AudioCue>>[
          <AudioCue>[cue('走り出した', 1500, 3500)],
        ],
      );
      final tracks = json['tracks'] as List<dynamic>;
      expect(tracks.length, 1);
      final t = tracks[0] as Map<String, dynamic>;
      expect(t['languageCode'], 'ja');
      expect(t['languageName'], '日本語');
      expect(t['isAutoGenerated'], false);
      expect(t['isTranslated'], false);
      final cues = t['cues'] as List<dynamic>;
      expect(cues.length, 1);
      expect(cues[0], <String, dynamic>{
        'text': '走り出した',
        'startMs': 1500,
        'endMs': 3500,
      });
    });

    test('cue 为空的轨被剔除（下载失败不占面板一格）', () {
      final json = serializeYoutubeCaptionTracks(
        <YoutubeCaptionTrack>[
          track('ja', '日本語', false),
          track('en', 'English', true),
        ],
        <List<AudioCue>>[
          <AudioCue>[cue('あ', 0, 1000)],
          <AudioCue>[], // en 轨下载失败/空
        ],
      );
      final tracks = json['tracks'] as List<dynamic>;
      expect(tracks.length, 1);
      expect((tracks[0] as Map<String, dynamic>)['languageCode'], 'ja');
    });
  });

  // TODO-1159 M0：导入对话框「网页地址」软警告的判定谓词——命中已知网页视频站
  // 且不是 YouTube 时才警告（YouTube 已由 resolveYoutubeSource 支持解析）。这里断言
  // 该组合谓词的真值表，守卫 YouTube 抑制 / 非 YouTube 保留不被回退。
  group('webpage warning suppression predicate (TODO-1159 M0)', () {
    bool warns(String url) => isKnownWebPageVideoUrl(url) && !isYoutubeUrl(url);
    test('YouTube 各形态一律不警告', () {
      expect(warns('https://www.youtube.com/watch?v=abc123'), isFalse);
      expect(warns('https://youtu.be/abc123'), isFalse);
      expect(warns('https://m.youtube.com/watch?v=abc'), isFalse);
      expect(warns('https://music.youtube.com/watch?v=abc'), isFalse);
      expect(warns('https://www.youtube-nocookie.com/embed/abc'), isFalse);
    });
    test('非 YouTube 网页视频站仍保留警告', () {
      expect(warns('https://www.netflix.com/watch/1'), isTrue);
      expect(warns('https://www.bilibili.com/video/BV1'), isTrue);
      expect(warns('https://www.nicovideo.jp/watch/sm1'), isTrue);
    });
    test('普通直链不警告', () {
      expect(warns('https://cdn.example.com/a.m3u8'), isFalse);
      expect(warns('https://example.com/video.mp4'), isFalse);
    });
  });

  // TODO-1307 A1：多 client 兜底顺序——androidVr 首选（零回归），失败才逐个回落。
  // BUG-1832：链里补入 android（实测存在只有它能出流的视频，如 D8uACXBAqkE），并排在
  // ios 之前（android 成功 ~3s，ios 取流失败要等满首流 HEAD 403 探测 ~16s）。
  group('A1 多 client 兜底顺序 (TODO-1307)', () {
    test(
      'kYoutubeManifestClientFallback = visionos -> androidVr -> android -> ios -> tv',
      () {
        expect(kYoutubeManifestClientFallback.length, 5);
        expect(
          identical(kYoutubeManifestClientFallback[0], kYoutubeVisionOsClient),
          isTrue,
          reason: 'BUG-2526：visionos 必须首选——android 的 DASH 流无 PO token 只放前 60 秒',
        );
        expect(
          identical(
            kYoutubeManifestClientFallback[1],
            yt.YoutubeApiClient.androidVr,
          ),
          isTrue,
          reason: 'androidVr 保留作兜底（其直链无需签名解密、libmpv 普通 UA 可拉取）',
        );
        expect(
          identical(
            kYoutubeManifestClientFallback[2],
            yt.YoutubeApiClient.android,
          ),
          isTrue,
          reason: 'BUG-1832：android 缺席会让只有它能出流的视频彻底打不开',
        );
        expect(
          identical(kYoutubeManifestClientFallback[3], yt.YoutubeApiClient.ios),
          isTrue,
        );
        expect(
          identical(kYoutubeManifestClientFallback[4], yt.YoutubeApiClient.tv),
          isTrue,
        );
      },
    );
  });

  // TODO-1307 字幕后置入口：best-effort，无法解析出 videoId 时返回空 cue，绝不抛/阻断播放。
  group('resolveYoutubeCaptions best-effort (TODO-1307)', () {
    test('无法解析的 URL -> 空 cue、不联网、不抛', () async {
      expect(await resolveYoutubeCaptions('not a youtube url'), isEmpty);
      expect(await resolveYoutubeCaptions(''), isEmpty);
    });
  });
}
