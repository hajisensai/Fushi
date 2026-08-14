import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/jimaku_search_seed.dart';
import 'package:fushi/src/pages/implementations/jimaku_subtitle_dialog.dart';
import 'package:fushi/utils.dart';

/// Jimaku 对话框的**身份优先检索**与**失败可见性**。
///
/// 三个真实故障：
/// 1. 库里显示名是中文译名时搜不到——app 明明存着这个视频的 AniList ID，却还在拿显示名
///    去 AniList 模糊匹配（中文长串匹配不上）。
/// 2. 填了集数再点搜索，系列列表整个消失且搜不出结果——`_search` 先清空系列列表、再等一次
///    网络往返回填，中间任何失败（AniList 限流 fail-open）都会让用户永久失去系列选择面。
/// 3. 下载失败的提示弹在对话框**底下**（SnackBar 挂在被 modal 盖住的页面 Scaffold 上），
///    而且只有一句「下载失败」，401/429/404 长得一模一样。
void main() {
  late List<String> requests;

  Future<void> pumpDialog(
    WidgetTester tester, {
    required MockClient client,
    JimakuSearchSeed seed = const JimakuSearchSeed(),
    String initialQuery = 'Re:ゼロから始める異世界生活',
    List<AniListMedia>? series,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (BuildContext ctx) {
            return ElevatedButton(
              onPressed: () => showDialog<String>(
                context: ctx,
                builder: (_) => JimakuSubtitleDialog(
                  initialQuery: initialQuery,
                  initialApiKey: 'TEST_KEY',
                  onApiKeyChanged: (_) async {},
                  saveDirectory: '/tmp/jimaku',
                  seed: seed,
                  httpClientFactory: () async => client,
                  debugInitialSeriesMatches: series,
                ),
              ),
              child: const Text('open'),
            );
          }),
        ),
      ),
    );
    await tester.tap(find.text('open'), warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  setUp(() => requests = <String>[]);

  MockClient recordingClient({
    String entriesBody =
        '[{"id":7,"name":"Re:Zero kara Hajimeru Isekai Seikatsu"}]',
    String filesBody =
        '[{"name":"Re Zero - 01.ja.srt","url":"https://jimaku.cc/file/1"}]',
    String anilistBody = '{"data":{"Page":{"media":[]}}}',
    int filesStatus = 200,
  }) =>
      MockClient((http.Request request) async {
        requests.add(request.url.toString());
        if (request.url.host.contains('anilist')) {
          return http.Response.bytes(utf8.encode(anilistBody), 200);
        }
        if (request.url.path.endsWith('/entries/search')) {
          return http.Response.bytes(utf8.encode(entriesBody), 200);
        }
        return http.Response.bytes(utf8.encode(filesBody), filesStatus);
      });

  testWidgets('已知 AniList id 时直接按 id 检索，完全不碰 AniList 文本匹配',
      (WidgetTester tester) async {
    await pumpDialog(
      tester,
      client: recordingClient(),
      seed: const JimakuSearchSeed(
        anilistId: 21355,
        queries: <String>['Re:ゼロから始める異世界生活'],
      ),
    );

    await tester.tap(find.text(t.video_jimaku_search));
    await tester.pumpAndSettle();

    // 中文译名在 AniList 上匹配不到，而 id 是确定的——有 id 就别再去猜名字。
    expect(requests.any((String u) => u.contains('anilist.co')), isFalse);
    expect(
      requests.any((String u) => u.contains('anilist_id=21355')),
      isTrue,
      reason: '刮削存下来的 AniList id 必须直接用于检索 Jimaku',
    );
  });

  testWidgets('用户改过番名后不再套用刮削 id（按他自己的词搜）', (WidgetTester tester) async {
    await pumpDialog(
      tester,
      client: recordingClient(),
      seed: const JimakuSearchSeed(
        anilistId: 21355,
        queries: <String>['Re:ゼロから始める異世界生活'],
      ),
    );

    await tester.enterText(
        find.widgetWithText(TextField, t.video_jimaku_query), '別のアニメ');
    await tester.tap(find.text(t.video_jimaku_search));
    await tester.pumpAndSettle();

    expect(requests.any((String u) => u.contains('anilist.co')), isTrue,
        reason: '用户自己改了番名，应按他的词重新解析系列');
  });

  testWidgets('AniList 这一跳空手而归时，已有的系列列表不被清空', (WidgetTester tester) async {
    // 预置两个系列（= 用户已经搜过一次的状态），再让 AniList 返回空（限流/抖动）。
    await pumpDialog(
      tester,
      client: recordingClient(anilistBody: '{"data":{"Page":{"media":[]}}}'),
      series: const <AniListMedia>[
        AniListMedia(
            id: 21355, romaji: 'Re:Zero kara Hajimeru Isekai Seikatsu'),
        AniListMedia(id: 119661, romaji: 'Re:Zero 2nd Season Part 2'),
      ],
    );
    expect(find.text('Re:Zero 2nd Season Part 2'), findsOneWidget);

    // 只在集数框填个数字再搜（用户报的正是这一步之后系列没了）。
    await tester.enterText(
        find.widgetWithText(TextField, t.video_jimaku_episode), '4');
    await tester.tap(find.text(t.video_jimaku_search));
    await tester.pumpAndSettle();

    expect(
      find.text('Re:Zero 2nd Season Part 2'),
      findsOneWidget,
      reason: '系列列表要等一次网络往返才回填，提前清空会让用户在失败时永久失去选择面',
    );
  });

  testWidgets('下载失败的原因显示在对话框内部，并带上 HTTP 状态码', (WidgetTester tester) async {
    final MockClient client = MockClient((http.Request request) async {
      requests.add(request.url.toString());
      if (request.url.host.contains('anilist')) {
        return http.Response('{"data":{"Page":{"media":[]}}}', 200);
      }
      if (request.url.path.endsWith('/entries/search')) {
        return http.Response.bytes(
            utf8.encode('[{"id":7,"name":"Re:Zero"}]'), 200);
      }
      if (request.url.path.endsWith('/files')) {
        return http.Response.bytes(
          utf8.encode('[{"name":"ep01.ja.srt","url":"https://jimaku.cc/f/1"}]'),
          200,
        );
      }
      // 文件下载本身失败（key 过期）。
      return http.Response('forbidden', 403);
    });

    await pumpDialog(tester, client: client);
    await tester.tap(find.text(t.video_jimaku_search));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ep01.ja.srt'));
    await tester.pumpAndSettle();

    // 对话框是全屏 modal，SnackBar 会被它整个盖住——错误必须画在对话框内部。
    expect(find.byKey(const ValueKey<String>('jimaku-error-banner')),
        findsOneWidget);
    expect(find.textContaining('403'), findsOneWidget,
        reason: '401/429/404 是完全不同的三件事，只说「下载失败」等于什么都没说');
  });
}
