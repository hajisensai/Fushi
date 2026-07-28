import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/nyaa_client.dart';
import 'package:hibiki/src/media/video/anilist_client.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/anime_download_dialog.dart';

import '../helpers/test_platform_services.dart';

/// 「设置 → 视频 → 字幕 → 默认字幕语言」的生效链路专项测试
/// （`settings_schema_coverage_test` 的 `kCoveredElsewhere` 指向本文件）。
///
/// 该设置本身只是一个偏好；它的「生效」不在 reader CSS / 主题树里，而是在三个
/// Jimaku 界面打开时的**语言预选**上——没有该系列的语言记忆时用它兜底。故用
/// 三层咬住：偏好往返 → AppModel 归一（含仓库未就绪的回退）→ 番剧下载对话框
/// 真的按它预选语言 chip。
HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

const AniListMedia _kMedia = AniListMedia(
  id: 1,
  romaji: 'Test Anime',
  native: 'テスト・アニメ',
  episodes: 12,
);

const NyaaTorrent _kTorrent = NyaaTorrent(
  title: '[Group] Test Anime - 01 [1080p]',
  torrentUrl: 'https://nyaa.si/download/1.torrent',
  pageUrl: 'https://nyaa.si/view/1',
  infoHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  seeders: 100,
  leechers: 1,
  downloads: 1000,
  sizeText: '1.4 GiB',
  sizeBytes: 1503238553,
  categoryId: '1_2',
  trusted: false,
  remake: false,
  pubDate: null,
);

/// 只替换偏好读取与 HTTP 的 AppModel 替身：语言预选走的仍是生产代码路径。
class _FakeAppModel extends AppModel {
  _FakeAppModel({required this.defaultLanguage})
      : super(testPlatformServices());

  final String defaultLanguage;

  @override
  String get jimakuApiKey => 'key';

  @override
  String get jimakuDefaultLanguage => defaultLanguage;

  // 以下两项只为让对话框能渲染（未 initialise 的 AppModel 读 prefsRepo 会抛）。
  @override
  QbConnectionConfig? get qbConnectionConfig => const QbConnectionConfig(
        backend: QbConnectionConfig.backendQbittorrent,
        baseUrl: 'http://127.0.0.1:1',
      );

  @override
  bool get torrentUploadIntroShown => true;

  @override
  Future<http.Client> createDownloadHttpClient() async =>
      MockClient((http.Request req) async {
        final String url = req.url.toString();
        if (url.contains('/entries/search')) {
          return http.Response.bytes(
            utf8.encode(jsonEncode(<Map<String, Object>>[
              <String, Object>{'id': 7, 'name': 'Test Anime'},
            ])),
            200,
          );
        }
        if (url.contains('/files')) {
          return http.Response.bytes(
            utf8.encode(jsonEncode(<Map<String, Object>>[
              <String, Object>{
                'name': 'Test Anime - 01.zh.srt',
                'url': 'https://jimaku.cc/f/1.srt',
              },
            ])),
            200,
          );
        }
        return http.Response('', 404);
      });
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  group('偏好往返', () {
    late HibikiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('默认「不限」，写入后读回同值', () async {
      expect(repo.jimakuDefaultLanguage, '');
      await repo.setJimakuDefaultLanguage('zh');
      expect(repo.jimakuDefaultLanguage, 'zh');
      await repo.setJimakuDefaultLanguage('');
      expect(repo.jimakuDefaultLanguage, '');
    });

    test('与每系列记忆是两张独立的表，互不覆盖', () async {
      await repo.setJimakuDefaultLanguage('ja');
      await repo.setJimakuPreferredLanguage('some series', 'zh');
      expect(repo.jimakuDefaultLanguage, 'ja');
      expect(repo.jimakuPreferredLanguages['some series'], 'zh');
    });
  });

  group('AppModel 归一', () {
    test('空 / 空白 → null（= 不限），有值 → 原码', () {
      expect(_FakeAppModel(defaultLanguage: '').jimakuDefaultLanguageOrNull,
          isNull);
      expect(_FakeAppModel(defaultLanguage: '   ').jimakuDefaultLanguageOrNull,
          isNull);
      expect(_FakeAppModel(defaultLanguage: 'ja').jimakuDefaultLanguageOrNull,
          'ja');
    });

    test('偏好仓库未就绪 → 回退「不限」而不是抛', () {
      // 未 initialise 的 AppModel（启动早期 / 测试替身）：`_prefsRepo` 为 null。
      final AppModel model = AppModel(testPlatformServices());
      expect(model.jimakuDefaultLanguage, '');
      expect(model.jimakuDefaultLanguageOrNull, isNull);
    });
  });

  // 两个语言各起一个 testWidgets：同一棵树里二次 pumpWidget 会复用
  // AnimeDownloadDialog 的 State（不重跑 initState），预选是 initState 里定的。
  testWidgets('番剧下载对话框：默认语言=中文 → 预选中文', (WidgetTester tester) async {
    await _pumpDialog(tester, 'zh');
    expect(_chipSelected(tester, '中文'), isTrue);
    expect(_chipSelected(tester, t.video_jimaku_language_all), isFalse);
  });

  testWidgets('番剧下载对话框：默认语言=不限 → 预选全部', (WidgetTester tester) async {
    await _pumpDialog(tester, '');
    expect(_chipSelected(tester, t.video_jimaku_language_all), isTrue);
    expect(_chipSelected(tester, '中文'), isFalse);
  });
}

Future<void> _pumpDialog(WidgetTester tester, String language) async {
  await tester.pumpWidget(ProviderScope(
    overrides: <Override>[
      appProvider
          .overrideWith((Ref ref) => _FakeAppModel(defaultLanguage: language)),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: AnimeDownloadDialog(
            embedded: true,
            debugInitialMedia: _kMedia,
            debugInitialTorrent: _kTorrent,
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  // 触发一次字幕搜索，语言选择器才会出现（它依赖搜到的条目）。
  await tester.tap(find.byIcon(Icons.search).last);
  await tester.pumpAndSettle();
}

bool _chipSelected(WidgetTester tester, String label) {
  final Iterable<ChoiceChip> chips = tester
      .widgetList<ChoiceChip>(find.byType(ChoiceChip))
      .where((ChoiceChip c) => (c.label as Text).data == label);
  expect(chips, isNotEmpty, reason: '语言 chip「$label」应存在');
  return chips.first.selected;
}
