import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/bilibili_clip_miner.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart';

/// bilibili 句子音频链路的解析层测试（纯离线，不打网络）。
///
/// 夹具是**实测响应体的真实形状**（2026-09-02 对 `api.bilibili.com` 实跑取得）：
///   · `x/web-interface/view?bvid=` → `{code:0, data:{title, cid, pages:[{page,cid,part,duration}]}}`
///   · `x/player/playurl?bvid=&cid=&fnval=4048&fourk=1`
///     → `{code:0, data:{dash:{duration, audio:[{id,baseUrl,bandwidth,codecs:'mp4a.40.2'}], video:[…]}}}`
/// 实测同时确认了两件影响设计的事实，两条都写成了断言的前提：
///   1. 音轨是 audio-only DASH 分片（`.m4s`），ffmpeg 可直接 `-ss/-t` 裁，产出真 AAC；
///   2. 未登录也拿得到最高档音轨（视频轨才受清晰度限制）——所以这条路只解析音轨。
void main() {
  const String viewBody = '''
{"code":0,"message":"OK","data":{
  "bvid":"BV1Este6wExx","aid":117191437455648,"cid":41473934959,
  "title":"从零开始的异世界生活 第四季",
  "pages":[
    {"cid":41473934959,"page":1,"part":"第13话","duration":258},
    {"cid":41473934960,"page":2,"part":"第14话","duration":261}
  ]}}
''';

  const String playurlBody = '''
{"code":0,"message":"OK","data":{"quality":32,"timelength":257382,
  "dash":{"duration":258,
    "video":[{"id":32,"baseUrl":"https://cdn/video-32.m4s","bandwidth":500000,
              "codecs":"avc1.640033","width":854,"height":480}],
    "audio":[
      {"id":30216,"baseUrl":"https://cdn/audio-30216.m4s","bandwidth":67224,
       "codecs":"mp4a.40.2","mimeType":"audio/mp4"},
      {"id":30280,"baseUrl":"https://cdn/audio-30280.m4s","bandwidth":173162,
       "codecs":"mp4a.40.2","mimeType":"audio/mp4"},
      {"id":30232,"baseUrl":"https://cdn/audio-30232.m4s","bandwidth":85370,
       "codecs":"mp4a.40.2","mimeType":"audio/mp4"}
    ]}}}
''';

  group('parseBilibiliViewResponse', () {
    test('按分 P 取 cid 与分 P 标题', () {
      final BilibiliVideoIdentity? p1 = parseBilibiliViewResponse(viewBody);
      expect(p1!.cid, 41473934959);
      expect(p1.partTitle, '第13话');
      expect(p1.durationSec, 258);
      expect(p1.displayTitle, '从零开始的异世界生活 第四季 - 第13话');

      final BilibiliVideoIdentity? p2 =
          parseBilibiliViewResponse(viewBody, page: 2);
      expect(p2!.cid, 41473934960, reason: '分 P 必须取对应那一 P 的 cid');
      expect(p2.partTitle, '第14话');
    });

    test('分 P 越界回落第 1 P（而不是抛或给出错的 cid）', () {
      expect(parseBilibiliViewResponse(viewBody, page: 99)!.cid, 41473934959);
      expect(parseBilibiliViewResponse(viewBody, page: 0)!.cid, 41473934959);
    });

    test('无 pages 的旧响应体回落到稿件级 cid', () {
      const String legacy =
          '{"code":0,"data":{"cid":123,"title":"单P稿件"}}';
      final BilibiliVideoIdentity? id = parseBilibiliViewResponse(legacy);
      expect(id!.cid, 123);
      expect(id.displayTitle, '单P稿件', reason: '没有分 P 名就不该拼出一个空后缀');
    });

    test('分 P 名与稿件名相同时不重复拼接', () {
      const String same =
          '{"code":0,"data":{"cid":1,"title":"标题","pages":['
          '{"cid":1,"page":1,"part":"标题","duration":10}]}}';
      expect(parseBilibiliViewResponse(same)!.displayTitle, '标题');
    });

    test('失败响应 / 畸形 JSON / 缺 cid 一律 null，不抛', () {
      expect(parseBilibiliViewResponse('{"code":-404,"data":null}'), isNull);
      expect(parseBilibiliViewResponse('not json'), isNull);
      expect(parseBilibiliViewResponse('{"code":0,"data":{"title":"x"}}'),
          isNull);
      expect(parseBilibiliViewResponse('{"code":0,"data":{"cid":0}}'), isNull,
          reason: 'cid=0 不是合法分片身份');
    });
  });

  group('parseBilibiliPlayurlResponse', () {
    test('取最高码率音轨（不是列表里的第一条）', () {
      final BilibiliPlayStreams? s =
          parseBilibiliPlayurlResponse(playurlBody);
      expect(s!.audioUrl, 'https://cdn/audio-30280.m4s',
          reason: '30280 的 bandwidth 最高；列表顺序不代表码率顺序');
      expect(s.durationSec, 258);
    });

    test('没有 DASH 音轨时返回 null —— 宁可失败也不出无声卡', () {
      expect(
          parseBilibiliPlayurlResponse(
              '{"code":0,"data":{"dash":{"audio":[]}}}'),
          isNull);
      expect(
          parseBilibiliPlayurlResponse(
              '{"code":0,"data":{"durl":[{"url":"https://cdn/x.flv"}]}}'),
          isNull,
          reason: 'durl 是混流，不当作可裁音轨静默降级');
      expect(parseBilibiliPlayurlResponse('{"code":-403,"data":null}'), isNull);
      expect(parseBilibiliPlayurlResponse('garbage'), isNull);
    });

    test('容忍 base_url 蛇形键与缺 bandwidth 的条目', () {
      const String mixed = '{"code":0,"data":{"dash":{"audio":['
          '{"base_url":"https://cdn/a.m4s"},'
          '{"baseUrl":"https://cdn/b.m4s","bandwidth":100}]}}}';
      expect(parseBilibiliPlayurlResponse(mixed)!.audioUrl,
          'https://cdn/b.m4s');
    });
  });

  group('BilibiliClipMiner', () {
    test('两次往返解析出音轨与标题，分 P 进 cid', () async {
      final List<Uri> calls = <Uri>[];
      final BilibiliClipMiner miner = BilibiliClipMiner(
        fetchJson: (Uri uri) async {
          calls.add(uri);
          return uri.path.contains('web-interface/view')
              ? viewBody
              : playurlBody;
        },
      );
      final BilibiliClipRequest req = await miner.buildRequest(
        bvid: 'BV1Este6wExx',
        page: 2,
        startMs: 61000,
        endMs: 64500,
        fields: const <String, String>{'expression': '正道'},
        sentence: '正道ではなく邪道',
      );
      expect(req.audioSource, 'https://cdn/audio-30280.m4s');
      expect(req.clipStartMs, 61000);
      expect(req.clipEndMs, 64500);
      expect(req.documentTitle, '从零开始的异世界生活 第四季 - 第14话');
      expect(calls.length, 2);
      expect(calls[1].queryParameters['cid'], '41473934960',
          reason: 'playurl 必须用第 2 P 的 cid');
      expect(calls[1].queryParameters['fnval'], '4048');
    });

    test('扩展带上来的页面标题优先于稿件标题', () async {
      final BilibiliClipMiner miner = BilibiliClipMiner(
        fetchJson: (Uri uri) async =>
            uri.path.contains('view') ? viewBody : playurlBody,
      );
      final BilibiliClipRequest req = await miner.buildRequest(
        bvid: 'BV1Este6wExx',
        startMs: 0,
        endMs: 1000,
        fields: const <String, String>{},
        sentence: 's',
        documentTitle: '用户此刻看到的标题',
      );
      expect(req.documentTitle, '用户此刻看到的标题');
    });

    test('TTL 内同一视频只解析一次（一场批量 N 张卡不重复打网络）', () async {
      int rounds = 0;
      final BilibiliClipMiner miner = BilibiliClipMiner(
        fetchJson: (Uri uri) async {
          rounds++;
          return uri.path.contains('view') ? viewBody : playurlBody;
        },
      );
      for (int i = 0; i < 3; i++) {
        await miner.buildRequest(
          bvid: 'BV1Este6wExx',
          startMs: i * 1000,
          endMs: i * 1000 + 500,
          fields: const <String, String>{},
          sentence: 's',
        );
      }
      expect(rounds, 2, reason: '3 张卡仍只有 view+playurl 两次请求');
    });

    test('不同分 P 不共用缓存', () async {
      int rounds = 0;
      final BilibiliClipMiner miner = BilibiliClipMiner(
        fetchJson: (Uri uri) async {
          rounds++;
          return uri.path.contains('view') ? viewBody : playurlBody;
        },
      );
      await miner.buildRequest(
          bvid: 'BV1x', page: 1, startMs: 0, endMs: 1,
          fields: const <String, String>{}, sentence: 's');
      await miner.buildRequest(
          bvid: 'BV1x', page: 2, startMs: 0, endMs: 1,
          fields: const <String, String>{}, sentence: 's');
      expect(rounds, 4, reason: '分 P 是不同的 cid，缓存键必须含它');
    });

    test('解析失败即抛，且不把失败的 future 留在缓存里卡住重试', () async {
      int rounds = 0;
      final BilibiliClipMiner miner = BilibiliClipMiner(
        fetchJson: (Uri uri) async {
          rounds++;
          // 第一轮 view 请求失败，之后恢复正常。
          if (rounds == 1) return null;
          return uri.path.contains('view') ? viewBody : playurlBody;
        },
      );
      await expectLater(
        miner.buildRequest(
            bvid: 'BV1x', startMs: 0, endMs: 1,
            fields: const <String, String>{}, sentence: 's'),
        throwsA(isA<StateError>()),
      );
      // 立刻重试（仍在 TTL 内）必须真的重新请求，而不是拿到同一个 rejected future。
      final BilibiliClipRequest ok = await miner.buildRequest(
          bvid: 'BV1x', startMs: 0, endMs: 1,
          fields: const <String, String>{}, sentence: 's');
      expect(ok.audioSource, 'https://cdn/audio-30280.m4s');
    });

    test('无 DASH 音轨时抛，不静默出一张没有音频的卡', () async {
      final BilibiliClipMiner miner = BilibiliClipMiner(
        fetchJson: (Uri uri) async => uri.path.contains('view')
            ? viewBody
            : '{"code":0,"data":{"dash":{"audio":[]}}}',
      );
      await expectLater(
        miner.buildRequest(
            bvid: 'BV1x', startMs: 0, endMs: 1,
            fields: const <String, String>{}, sentence: 's'),
        throwsA(isA<StateError>()),
      );
    });
  });

  // range 物化是 googlevideo 限速的专属绕行（`range=` 是**查询参数**、UA 要与 YouTube 铸流
  // 一致）。判据过去写成「有没有分离音轨」这个形状，任何别的站点的分离音轨走进去都会把
  // `range=` 当未知参数忽略、每片都返回整个文件，直到下满 maxBytes。
  group('audioSourceNeedsRangeMaterialization', () {
    test('googlevideo 及其子域要物化', () {
      expect(
          audioSourceNeedsRangeMaterialization(
              'https://rr3---sn-i3belne7.googlevideo.com/videoplayback?x=1'),
          isTrue);
      expect(audioSourceNeedsRangeMaterialization('https://googlevideo.com/a'),
          isTrue);
    });

    test('bilibili 的 audio-only m4s 不物化（实测可直接 seek）', () {
      expect(
          audioSourceNeedsRangeMaterialization(
              'https://xy1x2x3x4xy.mcdn.bilivideo.cn:8082/v1/resource/x.m4s?e=1'),
          isFalse);
      expect(
          audioSourceNeedsRangeMaterialization(
              'https://upos-sz-mirror08c.bilivideo.com/upgcxcode/x.m4s'),
          isFalse);
    });

    test('近似域名不得误命中（后缀匹配必须带点）', () {
      expect(
          audioSourceNeedsRangeMaterialization('https://notgooglevideo.com/a'),
          isFalse);
      expect(
          audioSourceNeedsRangeMaterialization('https://googlevideo.com.evil.test/a'),
          isFalse);
    });

    test('null / 空串 / 非 http / 本地路径一律 false', () {
      expect(audioSourceNeedsRangeMaterialization(null), isFalse);
      expect(audioSourceNeedsRangeMaterialization(''), isFalse);
      expect(audioSourceNeedsRangeMaterialization('C:/tmp/a.m4a'), isFalse);
      expect(audioSourceNeedsRangeMaterialization('file:///tmp/a.m4a'), isFalse);
    });
  });
}
