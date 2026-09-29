@Tags(<String>['preview'])
library;

// 本地「系列」详情页（`MediaCollectionDetailPage`）的真实像素预览：把 hero /
// 作品资料区 / 季 tab / 集卡搬进共享布局 `collection_detail_layout.dart` 前后各出
// 一套 PNG，逐像素比对必须为 0（不开真 app 看布局，记忆
// `widget-test-real-pixel-preview` 范式）。
//
// 只在环境变量 `FUSHI_PREVIEW=1` 时真跑（写 PNG 到磁盘、加载 Windows 系统字体、真
// 解码封面，不是断言型测试，CI 的 Linux 上没有那些字体）。输出目录由
// `FUSHI_PREVIEW_OUT` 指定，缺省 `../.claude/preview/collection_detail`（相对
// fushi/，不入库）；文件名后缀由 `FUSHI_PREVIEW_SUFFIX` 给（`before` / `after`）。
//
//   $env:FUSHI_PREVIEW='1'; $env:FUSHI_PREVIEW_SUFFIX='before'
//   flutter test --no-pub test/pages/collection_preview/
//
// 四组夹具 × 各两张（首屏 + 滚到底）：
//   ① legacy_full：横版 backdrop + 竖版海报 + 标题 logo + 刮削徽标/标签/简介 +
//      多季 + 已看/看到一半/续播高亮/远端云角标（桌面 1600×900 与移动 390×844）；
//   ② canonical_portrait：无 backdrop 只有竖版封面，规范作品资料区（事实行）；
//   ③ canonical_pending：规范作品但资料为空 → 「资料待补」卡。

import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteCollectionMembership, RemoteVideoInfo;
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

const String _fontFamily = 'PreviewCJK';

/// Windows 自带的可变字重 Noto Sans SC（.ttf，FontLoader 认；.ttc 不行）。
const List<String> _fontCandidates = <String>[
  r'C:\Windows\Fonts\NotoSansSC-VF.ttf',
  r'C:\Windows\Fonts\NotoSansJP-Regular.otf',
  r'C:\Windows\Fonts\segoeui.ttf',
];

String get _outDir =>
    Platform.environment['FUSHI_PREVIEW_OUT'] ??
    '${Directory.current.path}/../.claude/preview/collection_detail';

String get _suffix => Platform.environment['FUSHI_PREVIEW_SUFFIX'] ?? 'shot';

/// 生成一张有辨识度的图：按名字哈希取色的渐变 + 首字。[transparent] 出透明底
/// （标题 logo）。
Future<Uint8List> _renderImage(
  String label, {
  required int w,
  required int h,
  bool transparent = false,
}) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final double hue = (label.hashCode % 360).toDouble();
  if (!transparent) {
    final Color a = HSLColor.fromAHSL(1, hue, 0.55, 0.38).toColor();
    final Color b = HSLColor.fromAHSL(1, (hue + 50) % 360, 0.6, 0.18).toColor();
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(w.toDouble(), h.toDouble()),
          <Color>[a, b],
        ),
    );
  }
  final ui.ParagraphBuilder builder =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(
            fontSize: transparent ? h * 0.55 : (w > h ? h * 0.3 : w * 0.35),
            fontFamily: _fontFamily,
            fontWeight: FontWeight.w700,
            textAlign: TextAlign.center,
          ),
        )
        ..pushStyle(ui.TextStyle(color: Colors.white.withValues(alpha: 0.9)))
        ..addText(transparent ? label : String.fromCharCode(label.runes.first));
  final ui.Paragraph paragraph = builder.build()
    ..layout(ui.ParagraphConstraints(width: w.toDouble()));
  canvas.drawParagraph(paragraph, Offset(0, h / 2 - paragraph.height / 2));
  final ui.Image image = await recorder.endRecording().toImage(w, h);
  final ByteData? bytes = await image.toByteData(
    format: ui.ImageByteFormat.png,
  );
  image.dispose();
  return bytes!.buffer.asUint8List();
}

Future<void> _loadFont() async {
  for (final String path in _fontCandidates) {
    final File file = File(path);
    if (!file.existsSync()) continue;
    final Uint8List bytes = await file.readAsBytes();
    final FontLoader loader = FontLoader(_fontFamily)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
    return;
  }
  throw StateError('no preview font found: $_fontCandidates');
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.runAsync(() async {
    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage(
      pixelRatio: tester.view.devicePixelRatio,
    );
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    final File out = File('$_outDir/${name}_$_suffix.png');
    out.parent.createSync(recursive: true);
    await out.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

/// 让真实解码的封面进到帧里：runAsync 里放几拍真实时间再 pump。
Future<void> _settleWithImages(WidgetTester tester) async {
  await tester.pumpAndSettle();
  for (int i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

/// 滚到页面最底（jumpTo 精确到 maxScrollExtent，不带惯性，两次跑落点一致）。
Future<void> _scrollToEnd(WidgetTester tester) async {
  final ScrollableState scrollable = tester.state<ScrollableState>(
    find.byType(Scrollable).first,
  );
  scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
  await _settleWithImages(tester);
}

void _setView(WidgetTester tester, Size logical, double dpr) {
  tester.view.physicalSize = logical * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 一组夹具落盘后的句柄：DB + 合集行 + 成员槽装载器。
class _Fixture {
  _Fixture({
    required this.db,
    required this.collection,
    required this.loadEpisodes,
    required this.remote,
  });

  final FushiDatabase db;
  final MediaCollectionRow collection;
  final Future<List<CollectionEpisodeSlot>> Function() loadEpisodes;
  final CollectionRemoteContext? remote;
}

/// 夹具图片目录（每个 test 一份，tearDown 删）。
Future<Directory> _imageDir() async =>
    Directory.systemTemp.createTempSync('fushi-collection-preview');

Future<String> _writeImage(
  Directory dir,
  String name, {
  required int w,
  required int h,
  bool transparent = false,
}) async {
  final File file = File('${dir.path}/$name.png');
  await file.writeAsBytes(
    await _renderImage(name, w: w, h: h, transparent: transparent),
  );
  return file.path;
}

/// 成员视频：S01E01~E04 + S02E01~E02 本地，S01E05 只在对端。E01 已看完、E02 看到
/// 12:34（最近播放 → 续播落在 E02）、其余未看。
Future<List<VideoBookRow>> _seedMembers(
  FushiDatabase db,
  Directory images,
  int collectionId,
) async {
  const List<String> titles = <String>[
    'Show S01E01',
    'Show S01E02',
    'Show S01E03',
    'Show S01E04',
    'Show S02E01',
    'Show S02E02',
  ];
  final List<VideoBookRow> rows = <VideoBookRow>[];
  for (int i = 0; i < titles.length; i++) {
    final String title = titles[i];
    final String uid = 'video/${title.split(' ').last.toLowerCase()}';
    // 第 3、4 集不给缩略图 → 占位图标路径也进图。
    final String? cover = (i == 2 || i == 3)
        ? null
        : await _writeImage(images, 'thumb_$i', w: 640, h: 360);
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: Value<String>(uid),
        title: Value<String>(title),
        videoPath: Value<String>('/v/$title.mkv'),
        coverPath: Value<String?>(cover),
        completedAt: i == 0
            ? Value<DateTime?>(DateTime(2026, 1, 2))
            : const Value<DateTime?>(null),
        lastPositionMs: Value<int>(i == 1 ? 754000 : 0),
        lastPlayedAt: Value<int?>(
          i == 0
              ? DateTime(2026, 1, 2).millisecondsSinceEpoch
              : i == 1
              ? DateTime(2026, 1, 3).millisecondsSinceEpoch
              : null,
        ),
        importedAt: Value<int?>(DateTime(2026, 1, 1).millisecondsSinceEpoch),
      ),
    );
    await db.addToCollection(collectionId, MediaKind.video, uid);
    rows.add((await db.getVideoBookByBookUid(uid))!);
  }
  // 集级刮削：E01 有集名 + 集简介（集卡两行简介路径）。
  await db.upsertVideoScrapeMeta(
    VideoScrapeMetaCompanion.insert(
      bookUid: 'video/s01e01',
      source: 'tmdb',
      subjectId: '100',
      title: '出会い',
      summary: const Value<String?>('主角与伙伴初次相遇的一集。命运的齿轮从这一刻开始转动，谁也没有料到后来的一切。'),
      episodeNumber: const Value<int?>(1),
      scrapedAt: DateTime(2026),
    ),
  );
  return rows;
}

RemoteVideoInfo _remoteEpisode() => const RemoteVideoInfo(
  id: 'video/s01e05',
  title: 'Show S01E05',
  collection: RemoteCollectionMembership(
    collectionName: '转生王女与天才令嬢的魔法革命',
    collectionType: 'playlist',
    sortIndex: 4,
  ),
);

MediaCollectionRow _collectionRow(int id, String name, String coverPath) =>
    MediaCollectionRow(
      id: id,
      name: name,
      collectionType: 'playlist',
      coverSource: null,
      coverPath: coverPath,
      sortOrder: 0,
      createdAt: 0,
      orderUpdatedAt: 0,
    );

/// ① legacy：无规范作品，hero 走旧 v68 投影（简介 / 标签 / 徽标全在 hero 里），
/// 横版 backdrop + 竖版海报卡 + 标题 logo。
Future<_Fixture> _legacyFull(FushiDatabase db, Directory images) async {
  const String name = '转生王女与天才令嬢的魔法革命';
  final int collectionId = await db.createMediaCollection(
    name,
    collectionType: 'playlist',
  );
  final List<VideoBookRow> rows = await _seedMembers(db, images, collectionId);
  final String poster = await _writeImage(images, 'poster', w: 400, h: 600);
  await db.updateMediaCollectionCoverPath(collectionId, poster);
  await db.upsertCollectionScrapeMeta(
    CollectionScrapeMetaCompanion.insert(
      collectionId: Value<int>(collectionId),
      source: 'tmdb',
      subjectId: '100',
      title: name,
      originalTitle: const Value<String?>('転生王女と天才令嬢の魔法革命'),
      summary: const Value<String?>(
        '帕雷蒂亚王国的王女安妮斯菲亚痴迷魔法却毫无魔法才能，某夜她驾着自制的魔法扫帚闯进舞会，'
        '正撞见弟弟阿尔加尔德当众解除与天才令嬢欧菲莉亚的婚约。安妮把欧菲莉亚带回自己的离宫，'
        '两位少女由此携手掀起一场魔法革命。',
      ),
      airDate: const Value<String?>('2023-01-04'),
      rating: const Value<double?>(8.2),
      ratingCount: const Value<int?>(1234),
      episodeCount: const Value<int?>(12),
      tagsJson: const Value<String?>(
        '[{"name":"奇幻","count":900},{"name":"百合","count":800},'
        '{"name":"异世界","count":700},{"name":"魔法","count":600}]',
      ),
      scrapedAt: DateTime(2026, 1, 1),
    ),
  );
  final String backdrop = await _writeImage(
    images,
    'backdrop',
    w: 1280,
    h: 720,
  );
  final String logo = await _writeImage(
    images,
    'MAHOKAKU',
    w: 600,
    h: 180,
    transparent: true,
  );
  await db.replaceMediaImagesForCollection(collectionId, <MediaImagesCompanion>[
    MediaImagesCompanion.insert(
      collectionId: Value<int?>(collectionId),
      kind: MediaImageKind.backdrop.dbValue,
      path: backdrop,
    ),
    MediaImagesCompanion.insert(
      collectionId: Value<int?>(collectionId),
      kind: MediaImageKind.logo.dbValue,
      path: logo,
    ),
  ]);
  final RemoteVideoInfo remote = _remoteEpisode();
  return _Fixture(
    db: db,
    collection: _collectionRow(collectionId, name, poster),
    loadEpisodes: () async => <CollectionEpisodeSlot>[
      for (int i = 0; i < 4; i++) CollectionEpisodeSlot.local(rows[i]),
      CollectionEpisodeSlot.remote(remote),
      for (int i = 4; i < rows.length; i++)
        CollectionEpisodeSlot.local(rows[i]),
    ],
    remote: CollectionRemoteContext(
      loadRemoteVideos: () async => <RemoteVideoInfo>[remote],
      openEpisode: (RemoteVideoInfo _, List<RemoteVideoInfo> __, int ___) {},
    ),
  );
}

/// ②/③ canonical：v77 规范作品；[withDetails] 决定资料区是「事实行」还是
/// 「资料待补」卡。无横版背景，hero 只有竖版封面（LandscapeCoverImage 模糊垫底）。
Future<_Fixture> _canonical(
  FushiDatabase db,
  Directory images, {
  required bool withDetails,
}) async {
  const String name = '无职转生 ～到了异世界就拿出真本事～';
  final int collectionId = await db.createMediaCollection(
    name,
    collectionType: 'playlist',
  );
  final List<VideoBookRow> rows = await _seedMembers(db, images, collectionId);
  final String poster = await _writeImage(images, 'poster2', w: 400, h: 600);
  await db.updateMediaCollectionCoverPath(collectionId, poster);
  final int workId = await db.upsertVideoMetadataWork(
    VideoMetadataWorksCompanion.insert(
      collectionId: Value<int?>(collectionId),
      mediaType: 'tv',
      title: name,
      originalTitle: const Value<String?>('無職転生 ～異世界行ったら本気だす～'),
      overview: withDetails
          ? const Value<String?>(
              '34 岁的家里蹲尼特在被赶出家门的当天遭遇车祸身亡，醒来时已转生为剑与魔法世界里的婴儿鲁迪乌斯。'
              '带着前世的记忆与悔恨，他决心这一次要认真活下去。',
            )
          : const Value<String?>(null),
      premiereDate: const Value<String?>('2021-01-11'),
      year: const Value<int?>(2021),
      rating: const Value<double?>(8.4),
      ratingCount: const Value<int?>(5678),
      runtimeMinutes: const Value<int?>(24),
      status: const Value<String?>('Ended'),
      contentRating: withDetails
          ? const Value<String?>('TV-14')
          : const Value<String?>(null),
      updatedAt: 1,
    ),
  );
  if (withDetails) {
    await db.replaceVideoMetadataTermsForWork(
      workId: workId,
      terms: <VideoMetadataTermsCompanion>[
        for (final (String key, String kind, String value)
            in const <(String, String, String)>[
              ('genre:fantasy', 'genre', '奇幻'),
              ('genre:adventure', 'genre', '冒险'),
              ('studio:bind', 'studio', 'Studio Bind'),
              ('country:jp', 'country', 'JP'),
              ('keyword:isekai', 'keyword', '异世界'),
            ])
          VideoMetadataTermsCompanion.insert(
            termKey: key,
            kind: kind,
            name: value,
            normalizedName: value.toLowerCase(),
          ),
      ],
      mappings: <VideoMetadataWorkTermsCompanion>[
        for (final (int i, String key) in const <String>[
          'genre:fantasy',
          'genre:adventure',
          'studio:bind',
          'country:jp',
          'keyword:isekai',
        ].indexed)
          VideoMetadataWorkTermsCompanion.insert(
            workId: workId,
            termKey: key,
            sortOrder: Value<int>(i),
          ),
      ],
    );
    await db.upsertVideoMetadataPeople(<VideoMetadataPeopleCompanion>[
      VideoMetadataPeopleCompanion.insert(
        personKey: 'director',
        name: '岡本学',
        updatedAt: 1,
      ),
      VideoMetadataPeopleCompanion.insert(
        personKey: 'voice',
        name: '内山夕実',
        updatedAt: 1,
      ),
    ]);
    await db.upsertVideoMetadataCharacters(<VideoMetadataCharactersCompanion>[
      VideoMetadataCharactersCompanion.insert(
        characterKey: 'rudeus',
        name: '鲁迪乌斯',
        updatedAt: 1,
      ),
    ]);
    await db.replaceVideoMetadataCredits(
      workId: workId,
      credits: <VideoMetadataCreditsCompanion>[
        VideoMetadataCreditsCompanion.insert(
          personKey: 'director',
          creditKind: 'director',
          sortOrder: const Value<int>(0),
        ),
        VideoMetadataCreditsCompanion.insert(
          personKey: 'voice',
          characterKey: const Value<String?>('rudeus'),
          creditKind: 'voice_actor',
          roleName: const Value<String>('鲁迪乌斯'),
          sortOrder: const Value<int>(1),
        ),
      ],
    );
  }
  final int seasonId = await db.upsertVideoMetadataSeason(
    VideoMetadataSeasonsCompanion.insert(
      workId: workId,
      seasonNumber: 1,
      title: const Value<String?>('第 1 季'),
      updatedAt: 1,
    ),
  );
  await db.upsertVideoMetadataEpisode(
    VideoMetadataEpisodesCompanion.insert(
      seasonId: seasonId,
      bookUid: const Value<String?>('video/s01e02'),
      episodeNumber: 2,
      title: const Value<String?>('师父'),
      overview: const Value<String?>('洛琪希成为鲁迪乌斯的家庭教师，开始教授他魔法。'),
      updatedAt: 1,
    ),
  );
  return _Fixture(
    db: db,
    collection: _collectionRow(collectionId, name, poster),
    loadEpisodes: () async => <CollectionEpisodeSlot>[
      for (final VideoBookRow row in rows) CollectionEpisodeSlot.local(row),
    ],
    remote: null,
  );
}

Widget _harness(GlobalKey key, _Fixture fixture, Size size) {
  return TranslationProvider(
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF6750A4),
        fontFamily: _fontFamily,
      ),
      home: RepaintBoundary(
        key: key,
        child: SizedBox.fromSize(
          size: size,
          child: MediaCollectionDetailPage(
            database: fixture.db,
            collection: fixture.collection,
            loadEpisodes: fixture.loadEpisodes,
            onOpenEpisode: (VideoBookRow _) {},
            remote: fixture.remote,
            onChanged: () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  // 像素预览只在 FUSHI_PREVIEW=1 时跑（见文件头）。
  final bool skip = Platform.environment['FUSHI_PREVIEW'] != '1';
  late FushiDatabase db;
  late Directory images;

  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    images = await _imageDir();
  });

  tearDown(() async {
    await db.close();
    images.deleteSync(recursive: true);
  });

  Future<void> shoot(
    WidgetTester tester,
    _Fixture fixture,
    String name,
    Size size,
    double dpr,
  ) async {
    _setView(tester, size, dpr);
    await tester.runAsync(_loadFont);
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(_harness(key, fixture, size));
    await _settleWithImages(tester);
    await _capture(tester, key, '${name}_top');
    await _scrollToEnd(tester);
    await _capture(tester, key, '${name}_bottom');
  }

  testWidgets('01 legacy 全量 · desktop', (WidgetTester tester) async {
    // 夹具里真出 PNG（engine toImage）要在 runAsync 的真实事件循环里跑。
    final _Fixture fixture = (await tester.runAsync(
      () => _legacyFull(db, images),
    ))!;
    await shoot(
      tester,
      fixture,
      '01_legacy_full_desktop',
      const Size(1600, 900),
      1.0,
    );
  }, skip: skip);

  testWidgets('02 canonical 竖版封面 + 资料区 · desktop', (WidgetTester tester) async {
    final _Fixture fixture = (await tester.runAsync(
      () => _canonical(db, images, withDetails: true),
    ))!;
    await shoot(
      tester,
      fixture,
      '02_canonical_portrait_desktop',
      const Size(1600, 900),
      1.0,
    );
  }, skip: skip);

  testWidgets('03 canonical 资料待补 · desktop', (WidgetTester tester) async {
    final _Fixture fixture = (await tester.runAsync(
      () => _canonical(db, images, withDetails: false),
    ))!;
    await shoot(
      tester,
      fixture,
      '03_canonical_pending_desktop',
      const Size(1600, 900),
      1.0,
    );
  }, skip: skip);

  testWidgets('04 legacy 全量 · mobile', (WidgetTester tester) async {
    // 夹具里真出 PNG（engine toImage）要在 runAsync 的真实事件循环里跑。
    final _Fixture fixture = (await tester.runAsync(
      () => _legacyFull(db, images),
    ))!;
    await shoot(
      tester,
      fixture,
      '04_legacy_full_mobile',
      const Size(390, 844),
      2.0,
    );
  }, skip: skip);
}
