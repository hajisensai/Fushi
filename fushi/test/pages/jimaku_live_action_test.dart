import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/pages/implementations/jimaku_subtitle_dialog.dart';
import 'package:fushi/utils.dart';

/// Jimaku 自动获取字幕对话框的「分类」（动画 / 真人 / 全部）行为。
///
/// 根因回顾：Jimaku 服务端把 `anime` 当硬相等过滤且缺省 `true`，而对话框此前从不传这个
/// 参数，于是站点 Live Action 页上的真人剧字幕在 app 内一条都取不到；同时它无条件先查
/// AniList（GraphQL 写死 `type: ANIME`），对日剧纯属白等一次网络往返。
void main() {
  /// 记录本次用例发出的所有请求 URL。
  late List<String> requests;

  MockClient makeClient() => MockClient((http.Request request) async {
        requests.add(request.url.toString());
        if (request.url.host.contains('anilist')) {
          return http.Response('{"data":{"Page":{"media":[]}}}', 200);
        }
        if (request.url.path.endsWith('/entries/search')) {
          return http.Response.bytes(
            utf8.encode('[{"id":4,"name":"最愛","tmdb_id":"tv:126991",'
                '"flags":{"anime":false}}]'),
            200,
          );
        }
        return http.Response.bytes(
          utf8.encode('[{"name":"最愛 - 01.ja.srt","url":"https://x/1"}]'),
          200,
        );
      });

  Future<void> pumpDialog(WidgetTester tester) async {
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
                  initialQuery: '最愛',
                  initialApiKey: 'TEST_KEY',
                  onApiKeyChanged: (_) async {},
                  saveDirectory: '/tmp/jimaku',
                  httpClientFactory: () async => makeClient(),
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

  testWidgets('分类 chip 恒显示，默认选中动画', (WidgetTester tester) async {
    await pumpDialog(tester);

    expect(find.text(t.video_jimaku_category), findsOneWidget);
    // 搜不到恰恰是最需要换分类的时候，入口不能藏在「有结果」之后。
    expect(find.text(t.video_jimaku_category_live_action), findsOneWidget);

    final ChoiceChip animeChip = tester.widget<ChoiceChip>(
      find.byKey(jimakuCategoryChipKey(JimakuSearchScope.anime)),
    );
    expect(animeChip.selected, isTrue);
  });

  testWidgets('选真人 → 重搜时带 anime=false 且不再问 AniList',
      (WidgetTester tester) async {
    await pumpDialog(tester);

    await tester
        .tap(find.byKey(jimakuCategoryChipKey(JimakuSearchScope.liveAction)));
    await tester.pumpAndSettle();

    final List<String> searches = requests
        .where((String url) => url.contains('/entries/search'))
        .toList();
    expect(searches, isNotEmpty, reason: '切换分类必须重搜，分类是服务端检索参数');
    expect(searches.every((String url) => url.contains('anime=false')), isTrue,
        reason: '真人分类必须显式传 anime=false，否则服务端按缺省只回动画');
    // AniList 只有动画，真人分类下问它是白等一次往返、还会拿同名动画误导用户。
    expect(requests.any((String url) => url.contains('anilist')), isFalse);
  });

  testWidgets('默认动画分类仍先问 AniList 且搜 anime=true（不回归旧行为）',
      (WidgetTester tester) async {
    await pumpDialog(tester);

    await tester.tap(find.text(t.video_jimaku_search));
    await tester.pumpAndSettle();

    expect(requests.any((String url) => url.contains('anilist')), isTrue);
    final List<String> searches = requests
        .where((String url) => url.contains('/entries/search'))
        .toList();
    expect(searches, isNotEmpty);
    expect(searches.every((String url) => url.contains('anime=true')), isTrue);
  });

  testWidgets('选全部 → 动画与真人各查一次', (WidgetTester tester) async {
    await pumpDialog(tester);

    await tester.tap(find.byKey(jimakuCategoryChipKey(JimakuSearchScope.all)));
    await tester.pumpAndSettle();

    final List<String> searches = requests
        .where((String url) => url.contains('/entries/search'))
        .toList();
    // 服务端没有「不限分类」取值，只能两类各发一次。
    expect(searches.where((String u) => u.contains('anime=true')), isNotEmpty);
    expect(searches.where((String u) => u.contains('anime=false')), isNotEmpty);
  });
}
