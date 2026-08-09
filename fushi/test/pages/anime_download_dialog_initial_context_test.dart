import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/anime_download_dialog.dart';

import '../helpers/test_platform_services.dart';

/// TODO-2485：AnimeDownloadDialog 初始上下文入参。
/// ① initialMedia（合集绑 anilistId 时本地合成）→ 直达选种段：Nyaa 查询词与
///   字幕搜索词预填合集名、Jimaku 集号框预填 initialEpisode；
/// ② initialSearchQuery → 停在搜番段、搜索框预填；
/// ③ 全 null → 既有入口行为零变化（搜番段空搜索框）。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  final List<String> requestedUrls = <String>[];

  Future<http.Response> handler(http.Request request) async {
    final String url = request.url.toString();
    requestedUrls.add(url);
    if (url.contains('graphql.anilist.co')) {
      return http.Response(
        '{"data":{"Page":{"media":[]}}}',
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    if (url.contains('nyaa.si')) {
      return http.Response(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<rss version="2.0" xmlns:nyaa="https://nyaa.si/xmlns/nyaa">'
        '<channel></channel></rss>',
        200,
      );
    }
    if (url.contains('/entries/search')) {
      // 一条 Jimaku 条目：让对话框继续调 files 端点（集号过滤在那一步）。
      return http.Response(
        '[{"id":9,"name":"My Show","anilist_id":42}]',
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    return http.Response('[]', 200,
        headers: <String, String>{'content-type': 'application/json'});
  }

  setUp(requestedUrls.clear);

  Future<void> pumpDialog(
    WidgetTester tester, {
    AniListMedia? initialMedia,
    int? initialEpisode,
    String? initialSearchQuery,
  }) async {
    final _FakeAppModel appModel = _FakeAppModel(handler);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: AnimeDownloadDialog(
                embedded: true,
                showTasks: false,
                initialMedia: initialMedia,
                initialEpisode: initialEpisode,
                initialSearchQuery: initialSearchQuery,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Iterable<String> fieldTexts(WidgetTester tester) => tester
      .widgetList<TextField>(find.byType(TextField))
      .map((TextField f) => f.controller?.text ?? '');

  testWidgets('initialMedia + initialEpisode → 直达选种段并预填合集名/集号',
      (WidgetTester tester) async {
    await pumpDialog(
      tester,
      initialMedia: const AniListMedia(id: 42, romaji: 'My Show'),
      initialEpisode: 5,
    );

    // 选种段标志：Nyaa 查询词预填（搜番段没有这个值的输入框）。
    expect(fieldTexts(tester), contains('My Show'), reason: '直达选种段：查询词预填合集名');
    // 集号预填走真实数据流：Jimaku files 请求必须带 episode=5 过滤
    //（集号输入框在确认段才渲染，选种段断言请求参数而不是控件文本）。
    expect(
      requestedUrls.any((String url) => url.contains('episode=5')),
      isTrue,
      reason: 'initialEpisode 必须进入 Jimaku 按集过滤请求',
    );
  });

  testWidgets('initialSearchQuery → 搜番段搜索框预填', (WidgetTester tester) async {
    await pumpDialog(tester, initialSearchQuery: 'Some Title');

    expect(fieldTexts(tester), contains('Some Title'));
  });

  testWidgets('全 null → 既有入口行为零变化（搜番段空搜索框）', (WidgetTester tester) async {
    await pumpDialog(tester);

    expect(fieldTexts(tester), isNot(contains('My Show')));
    expect(fieldTexts(tester).every((String s) => s.isEmpty), isTrue,
        reason: '无初始上下文时不得预填任何输入框');
  });
}

/// 纯内存计划存储（widget 测试不碰真实文件）。
class _MemPlanStore extends AnimeDownloadPlanStore {
  _MemPlanStore() : super(baseDir: Directory('unused-mem-store'));

  @override
  Future<List<AnimeDownloadPlan>> loadAll() async =>
      const <AnimeDownloadPlan>[];

  @override
  Future<bool> save(AnimeDownloadPlan plan) async => true;

  @override
  Future<void> delete(String id) async {}
}

class _FakeAppModel extends AppModel {
  _FakeAppModel(this._httpHandler) : super(testPlatformServices());

  final Future<http.Response> Function(http.Request request) _httpHandler;
  final _MemPlanStore store = _MemPlanStore();

  @override
  String get jimakuApiKey => 'key';

  @override
  QbConnectionConfig? get qbConnectionConfig => const QbConnectionConfig(
        backend: QbConnectionConfig.backendQbittorrent,
        baseUrl: 'http://127.0.0.1:1',
      );

  @override
  bool get torrentUploadIntroShown => true;

  @override
  AnimeDownloadPlanStore? get animeDownloadPlanStore => store;

  @override
  Future<http.Client> createDownloadHttpClient() async =>
      MockClient(_httpHandler);
}
