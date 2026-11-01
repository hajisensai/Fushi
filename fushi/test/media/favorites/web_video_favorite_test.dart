// 反馈 KGC1ifR1a3：浏览器扩展看网页视频时收藏当前句 / 视频本身，写 App 收藏夹同一份收藏句；
// 收藏夹能跳回原网页的时间点。钉住：URL 规范化（收藏身份）、跳回地址生成（按站点带时间
// 参数 / 不支持的站点只开原网页）、扩展请求体解析、切换 / 只读读写真库。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/favorites/web_video_favorite.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  group('canonicalWebVideoUrl（收藏身份）', () {
    test('YouTube：分享短链 / 带时间 / 带列表 / m 子域归成同一条', () {
      const String want = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';
      for (final String raw in <String>[
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s',
        'https://youtu.be/dQw4w9WgXcQ?t=42',
        'https://m.youtube.com/watch?v=dQw4w9WgXcQ&list=PL1&index=3',
        'https://www.youtube.com/live/dQw4w9WgXcQ?si=abc',
      ]) {
        expect(canonicalWebVideoUrl(raw), want, reason: raw);
      }
      expect(
        canonicalWebVideoUrl('https://www.youtube.com/shorts/abc123?feature=x'),
        'https://www.youtube.com/shorts/abc123',
      );
    });

    test('niconico / bilibili / Netflix 去掉时间与会话参数', () {
      expect(
        canonicalWebVideoUrl(
          'https://www.nicovideo.jp/watch/sm9?from=30&ref=x',
        ),
        'https://www.nicovideo.jp/watch/sm9',
      );
      expect(
        canonicalWebVideoUrl('https://nico.ms/sm9'),
        'https://www.nicovideo.jp/watch/sm9',
      );
      expect(
        canonicalWebVideoUrl('https://sp.nicovideo.jp/watch/so123'),
        'https://www.nicovideo.jp/watch/so123',
      );
      expect(
        canonicalWebVideoUrl(
          'https://www.bilibili.com/video/BV1xx411c7mD?p=2&t=12&spm=a',
        ),
        'https://www.bilibili.com/video/BV1xx411c7mD?p=2',
      );
      expect(
        canonicalWebVideoUrl(
          'https://www.bilibili.com/video/BV1xx411c7mD/?p=1',
        ),
        'https://www.bilibili.com/video/BV1xx411c7mD',
      );
      expect(
        canonicalWebVideoUrl(
          'https://www.netflix.com/watch/80057281?trackId=1&tctx=0&t=99',
        ),
        'https://www.netflix.com/watch/80057281',
      );
    });

    test('其余站点：去片段与时间参数，其余查询保留', () {
      expect(
        canonicalWebVideoUrl('https://tver.jp/episodes/ep1?t=10&id=5#top'),
        'https://tver.jp/episodes/ep1?id=5',
      );
    });

    test('不是网页地址 → null（不可收藏）', () {
      for (final String raw in <String>[
        '',
        'chrome-extension://abc/side-panel.html',
        'file:///C:/v.mp4',
        'about:blank',
        'not a url',
      ]) {
        expect(canonicalWebVideoUrl(raw), isNull, reason: raw);
      }
    });
  });

  group('webVideoJumpTarget（跳回原网页的时间点）', () {
    test('YouTube t=<秒>s、niconico from=<秒>、bilibili t=<秒>', () {
      final WebVideoJumpTarget yt = webVideoJumpTarget(
        'https://youtu.be/dQw4w9WgXcQ',
        83900,
      )!;
      expect(yt.timed, isTrue);
      expect(
        yt.uri.toString(),
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=83s',
      );

      final WebVideoJumpTarget nico = webVideoJumpTarget(
        'https://www.nicovideo.jp/watch/sm9',
        125000,
      )!;
      expect(nico.timed, isTrue);
      expect(
        nico.uri.toString(),
        'https://www.nicovideo.jp/watch/sm9?from=125',
      );

      final WebVideoJumpTarget bili = webVideoJumpTarget(
        'https://www.bilibili.com/video/BV1xx411c7mD?p=2',
        61000,
      )!;
      expect(bili.timed, isTrue);
      expect(
        bili.uri.toString(),
        'https://www.bilibili.com/video/BV1xx411c7mD?p=2&t=61',
      );
    });

    test('Netflix / 通用站 / YouTube shorts 不能按时间点打开：只开原网页', () {
      for (final String url in <String>[
        'https://www.netflix.com/watch/80057281',
        'https://tver.jp/episodes/ep1',
        'https://www.youtube.com/shorts/abc123',
      ]) {
        final WebVideoJumpTarget target = webVideoJumpTarget(url, 5000)!;
        expect(target.timed, isFalse, reason: url);
        expect(target.uri.toString(), canonicalWebVideoUrl(url), reason: url);
      }
    });

    test('收藏的是视频本身（无时间点）→ 原网页、timed=false', () {
      final WebVideoJumpTarget target = webVideoJumpTarget(
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=9',
        null,
      )!;
      expect(target.timed, isFalse);
      expect(
        target.uri.toString(),
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      );
    });

    test('时间格式', () {
      expect(formatWebVideoPosition(0), '0:00');
      expect(formatWebVideoPosition(83900), '1:23');
      expect(formatWebVideoPosition(3723000), '1:02:03');
    });
  });

  group('站点名与标题清理', () {
    test('站点名：认得的用品牌名，其余用去 www. 的域名', () {
      expect(webVideoSiteLabel(Uri.parse('https://youtu.be/x')), 'YouTube');
      expect(
        webVideoSiteLabel(Uri.parse('https://www.nicovideo.jp/watch/sm9')),
        'niconico',
      );
      expect(
        webVideoSiteLabel(Uri.parse('https://www.netflix.com/watch/1')),
        'Netflix',
      );
      expect(webVideoSiteLabel(Uri.parse('https://www.tver.jp/e')), 'tver.jp');
    });

    test('去站点后缀与 YouTube 未读数前缀', () {
      expect(
        cleanWebVideoTitle('(3) 夏の歌 - YouTube', WebVideoSite.youtube),
        '夏の歌',
      );
      expect(cleanWebVideoTitle('第1話 - ニコニコ動画', WebVideoSite.niconico), '第1話');
      expect(cleanWebVideoTitle('作品 | Netflix', WebVideoSite.netflix), '作品');
      expect(cleanWebVideoTitle('  題 ', WebVideoSite.other), '題');
    });
  });

  group('ExtensionVideoFavoriteRequest.tryParse', () {
    test('切换句子：地址规范化、标题清理、毫秒取整', () {
      final ExtensionVideoFavoriteRequest r =
          ExtensionVideoFavoriteRequest.tryParse(<String, dynamic>{
            'op': 'toggle',
            'kind': 'sentence',
            'url': 'https://www.youtube.com/watch?v=abc&t=12',
            'title': '(2) 歌 - YouTube',
            'text': ' 夏が来た ',
            'startMs': 12345.6,
            'endMs': 14000,
          })!;
      expect(r.toggle, isTrue);
      expect(r.kind, WebVideoFavoriteKind.sentence);
      expect(r.url, 'https://www.youtube.com/watch?v=abc');
      expect(r.title, '歌');
      expect(r.text, '夏が来た');
      expect(r.startMs, 12346);
      expect(r.endMs, 14000);
    });

    test('只读：op 缺省 = state；视频收藏忽略句子字段', () {
      final ExtensionVideoFavoriteRequest r =
          ExtensionVideoFavoriteRequest.tryParse(<String, dynamic>{
            'kind': 'video',
            'url': 'https://www.netflix.com/watch/1?trackId=2',
            'text': '不该存',
            'startMs': 5,
          })!;
      expect(r.toggle, isFalse);
      expect(r.kind, WebVideoFavoriteKind.video);
      expect(r.url, 'https://www.netflix.com/watch/1');
      expect(r.text, '');
      expect(r.startMs, isNull);
    });

    test('不合契约 → null', () {
      for (final Map<String, dynamic> body in <Map<String, dynamic>>[
        <String, dynamic>{'op': 'toggle', 'kind': 'video'},
        <String, dynamic>{'op': 'toggle', 'kind': 'video', 'url': 3},
        <String, dynamic>{
          'op': 'toggle',
          'kind': 'video',
          'url': 'chrome-extension://x/y',
        },
        <String, dynamic>{
          'op': 'delete',
          'kind': 'video',
          'url': 'https://a.jp/v',
        },
        <String, dynamic>{
          'op': 'toggle',
          'kind': 'sentence',
          'url': 'https://a.jp/v',
          'text': '   ',
        },
      ]) {
        expect(ExtensionVideoFavoriteRequest.tryParse(body), isNull);
      }
    });
  });

  group('handleExtensionVideoFavorite（写 App 收藏夹同一份收藏句）', () {
    late FushiDatabase db;
    late FavoriteSentenceRepository repo;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = FavoriteSentenceRepository(db);
    });
    tearDown(() async => db.close());

    ExtensionVideoFavoriteRequest req(Map<String, dynamic> body) =>
        ExtensionVideoFavoriteRequest.tryParse(body)!;

    test('收藏当前句：落一条 web 来源收藏句（地址 / 站点 / 时间锚点 / 今日统计键），再点取消', () async {
      final DateTime now = DateTime(2026, 11, 1, 20, 30);
      final ExtensionVideoFavoriteState added =
          await handleExtensionVideoFavorite(
            repository: repo,
            now: now,
            request: req(<String, dynamic>{
              'op': 'toggle',
              'kind': 'sentence',
              'url': 'https://youtu.be/abc?t=5',
              'title': '歌 - YouTube',
              'text': '夏が来た',
              'startMs': 83000,
              'endMs': 85500,
            }),
          );
      expect(added.favorite, isTrue);
      expect(added.video, isFalse);
      expect(added.sentences.single.text, '夏が来た');
      expect(added.sentences.single.startMs, 83000);

      final FavoriteSentence row = (await repo.getAll()).single;
      expect(row.source, kFavoriteSentenceSourceWeb);
      expect(sentenceSourceKindOf(row.source), SentenceSourceKind.web);
      expect(row.bookKey, 'https://www.youtube.com/watch?v=abc');
      expect(row.bookTitle, '歌');
      expect(row.chapterLabel, 'YouTube');
      expect(row.normCharOffset, 83000);
      expect(row.normCharLength, 2500);
      expect(row.dateKey, FushiDatabase.statDateKeyOf(now));

      // 从另一种地址形态（带 t=）再点一次 = 同一条 → 取消收藏。
      final ExtensionVideoFavoriteState removed =
          await handleExtensionVideoFavorite(
            repository: repo,
            request: req(<String, dynamic>{
              'op': 'toggle',
              'kind': 'sentence',
              'url': 'https://www.youtube.com/watch?v=abc&t=83',
              'text': '夏が来た',
              'startMs': 83000,
            }),
          );
      expect(removed.favorite, isFalse);
      expect(removed.sentences, isEmpty);
      expect(await repo.getAll(), isEmpty);
    });

    test('收藏视频本身与收藏句互不影响；只读回整份状态', () async {
      await handleExtensionVideoFavorite(
        repository: repo,
        request: req(<String, dynamic>{
          'op': 'toggle',
          'kind': 'video',
          'url': 'https://www.netflix.com/watch/42?trackId=1',
          'title': '作品 | Netflix',
        }),
      );
      await handleExtensionVideoFavorite(
        repository: repo,
        request: req(<String, dynamic>{
          'op': 'toggle',
          'kind': 'sentence',
          'url': 'https://www.netflix.com/watch/42',
          'text': 'ただいま',
          'startMs': 1000,
          'endMs': 2000,
        }),
      );
      // 别的视频的收藏不串进来。
      await handleExtensionVideoFavorite(
        repository: repo,
        request: req(<String, dynamic>{
          'op': 'toggle',
          'kind': 'video',
          'url': 'https://www.netflix.com/watch/43',
        }),
      );

      final ExtensionVideoFavoriteState state =
          await handleExtensionVideoFavorite(
            repository: repo,
            request: req(<String, dynamic>{
              'op': 'state',
              'url': 'https://www.netflix.com/watch/42?tctx=9',
            }),
          );
      expect(state.favorite, isNull, reason: '只读不带切换结果');
      expect(state.video, isTrue);
      expect(state.sentences.map((WebVideoFavoritedLine l) => l.text), <String>[
        'ただいま',
      ]);
      expect(state.toJson(), <String, Object?>{
        'video': true,
        'sentences': <Map<String, Object?>>[
          <String, Object?>{'text': 'ただいま', 'startMs': 1000},
        ],
      });

      final FavoriteSentence videoRow = (await repo.getAll()).firstWhere(
        (FavoriteSentence s) =>
            s.text.isEmpty && s.bookKey == 'https://www.netflix.com/watch/42',
      );
      expect(videoRow.bookTitle, '作品');
      expect(videoRow.normCharOffset, isNull);

      // 取消视频收藏只删视频那条。
      final ExtensionVideoFavoriteState after =
          await handleExtensionVideoFavorite(
            repository: repo,
            request: req(<String, dynamic>{
              'op': 'toggle',
              'kind': 'video',
              'url': 'https://www.netflix.com/watch/42',
            }),
          );
      expect(after.favorite, isFalse);
      expect(after.video, isFalse);
      expect(after.sentences, hasLength(1));
    });

    test('同一句文本、不同时间点是两条收藏', () async {
      for (final int start in <int>[1000, 50000]) {
        await handleExtensionVideoFavorite(
          repository: repo,
          request: req(<String, dynamic>{
            'op': 'toggle',
            'kind': 'sentence',
            'url': 'https://www.nicovideo.jp/watch/sm9',
            'text': 'はい',
            'startMs': start,
          }),
        );
      }
      expect(await repo.getAll(), hasLength(2));
    });
  });
}
