@Tags(<String>['preview'])
library;

// 「媒体服务器」分区各页的真实像素预览（不开真 app 看布局，记忆
// `widget-test-real-pixel-preview` 范式）。
//
// 只在环境变量 `FUSHI_PREVIEW=1` 时真跑（`@Tags` 只是标记，裸跑目录时不会自动
// 排除，而它写 PNG 到磁盘、加载 Windows 系统字体、真解码封面，不是断言型测试，
// CI 的 Linux 上没有那些字体）。输出目录由 `FUSHI_PREVIEW_OUT` 指定，缺省
// `../.claude/preview/media_server`（相对 fushi/，不入库）。
//
//   $env:FUSHI_PREVIEW='1'; flutter test --no-pub test/pages/media_server/preview/

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_detail_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_grid_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_home_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_server_list_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/sync/remote_cover_cache.dart';
import 'package:fushi/utils.dart';

import '../fake_media_server_browser.dart';

const String _fontFamily = 'PreviewCJK';

/// Windows 自带的可变字重 Noto Sans SC（.ttf，FontLoader 认；.ttc 不行）。
const List<String> _fontCandidates = <String>[
  r'C:\Windows\Fonts\NotoSansSC-VF.ttf',
  r'C:\Windows\Fonts\NotoSansJP-Regular.otf',
  r'C:\Windows\Fonts\segoeui.ttf',
];

String get _outDir =>
    Platform.environment['FUSHI_PREVIEW_OUT'] ??
    '${Directory.current.path}/../.claude/preview/media_server';

/// 生成一张有辨识度的封面：按名字哈希取色的渐变 + 首字。
Future<Uint8List> _renderCover(String label, {required bool wide}) async {
  final int w = wide ? 640 : 400;
  final int h = wide ? 360 : 600;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final double hue = (label.hashCode % 360).toDouble();
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
  final ui.ParagraphBuilder builder =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(
            fontSize: wide ? 96 : 140,
            fontFamily: _fontFamily,
            textAlign: TextAlign.center,
          ),
        )
        ..pushStyle(ui.TextStyle(color: Colors.white.withValues(alpha: 0.85)))
        ..addText(String.fromCharCode(label.runes.first));
  final ui.Paragraph paragraph = builder.build()
    ..layout(ui.ParagraphConstraints(width: w.toDouble()));
  canvas.drawParagraph(paragraph, Offset(0, h / 2 - paragraph.height / 2));
  return _encodePng(recorder, w, h);
}

/// 生成一张标题 logo：透明底、粗体白字带阴影（Jellyfin `Logo` 图就是这形态）。
Future<Uint8List> _renderLogo(String label) async {
  const int w = 800;
  const int h = 220;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final ui.ParagraphBuilder builder =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(
            fontSize: 120,
            fontFamily: _fontFamily,
            fontWeight: FontWeight.w900,
            textAlign: TextAlign.left,
          ),
        )
        ..pushStyle(
          ui.TextStyle(
            color: Colors.white,
            shadows: const <Shadow>[
              Shadow(color: Color(0xCC000000), blurRadius: 18),
            ],
          ),
        )
        ..addText(label);
  final ui.Paragraph paragraph = builder.build()
    ..layout(ui.ParagraphConstraints(width: w.toDouble()));
  canvas.drawParagraph(paragraph, Offset(0, h / 2 - paragraph.height / 2));
  return _encodePng(recorder, w, h);
}

Future<Uint8List> _encodePng(ui.PictureRecorder recorder, int w, int h) async {
  final ui.Image image = await recorder.endRecording().toImage(w, h);
  final ByteData? bytes = await image.toByteData(
    format: ui.ImageByteFormat.png,
  );
  image.dispose();
  return bytes!.buffer.asUint8List();
}

class _PreviewBrowser extends FakeMediaServerBrowser {
  _PreviewBrowser({super.serverId, super.displayName, super.serverUrl});

  final Map<String, Uint8List> _covers = <String, Uint8List>{};

  @override
  String? coverUrl(
    MediaServerItem item, {
    int maxWidth = kMediaServerCoverMaxWidth,
    MediaServerImageKind kind = MediaServerImageKind.primary,
  }) {
    if (!item.hasCover) return null;
    if (kind == MediaServerImageKind.thumb && !item.hasThumb) return null;
    if (kind == MediaServerImageKind.backdrop && !item.hasBackdrop) return null;
    if (kind == MediaServerImageKind.logo && !item.hasLogo) return null;
    return 'cover|${item.name}|${kind.name}';
  }

  @override
  String? libraryCoverUrl(
    MediaServerLibrary library, {
    int maxWidth = kMediaServerCoverMaxWidth,
  }) => library.hasCover ? 'cover|${library.name}|library' : null;

  /// 库封面端点 404 的库（uhdnow 真实形态，BUG-2602）。
  static const Set<String> _libraryCover404 = <String>{'国产动漫'};

  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) async {
    final List<String> parts = coverUrl.split('|');
    if (parts[2] == 'library' && _libraryCover404.contains(parts[1])) {
      throw StateError('404 $coverUrl');
    }
    if (parts[2] == MediaServerImageKind.logo.name) {
      return _covers[coverUrl] ??= await _renderLogo(parts[1]);
    }
    final bool wide = parts[2] != 'primary';
    return _covers[coverUrl] ??= await _renderCover(parts[1], wide: wide);
  }
}

MediaServerItem _movie(
  String id,
  String name, {
  int? year,
  int minutes = 98,
  int positionMs = 0,
  bool played = false,
  double? rating,
  String? overview,
  List<String> genres = const <String>[],
}) => MediaServerItem(
  id: id,
  name: name,
  type: MediaServerItemType.movie,
  productionYear: year,
  durationMs: minutes * 60 * 1000,
  positionMs: positionMs,
  played: played,
  hasCover: true,
  hasBackdrop: true,
  communityRating: rating,
  overview: overview,
  genres: genres,
);

MediaServerItem _series(
  String id,
  String name, {
  int? year,
  int? unplayed,
  int? childCount,
  int? episodeCount,
  double? rating,
  String? overview,
  List<String> genres = const <String>[],
  bool hasLogo = false,
}) => MediaServerItem(
  id: id,
  name: name,
  type: MediaServerItemType.series,
  productionYear: year,
  unplayedChildCount: unplayed,
  childCount: childCount,
  episodeCount: episodeCount,
  hasCover: true,
  hasBackdrop: true,
  hasLogo: hasLogo,
  communityRating: rating,
  overview: overview,
  genres: genres,
);

List<MediaServerItem> _episodes({
  required String seriesId,
  required String seriesName,
  required String seasonId,
  required int season,
  required int count,
  int playedUpTo = 0,
  int inProgress = -1,
}) => <MediaServerItem>[
  for (int i = 1; i <= count; i++)
    MediaServerItem(
      id: '$seasonId-e$i',
      name: '第 $i 話 ${_episodeTitles[(i - 1) % _episodeTitles.length]}',
      type: MediaServerItemType.episode,
      seriesId: seriesId,
      seriesName: seriesName,
      seasonId: seasonId,
      seasonNumber: season,
      episodeNumber: i,
      durationMs: 24 * 60 * 1000,
      // 奇数集带集简介、偶数集不带：集卡「有简介两行 / 无简介」两态都进预览。
      overview: i.isOdd ? '執事はこの日、主人の命を受けて屋敷の外へ。第 $i 話の出来事。' : null,
      hasCover: true,
      hasThumb: true,
      played: i <= playedUpTo,
      positionMs: i == inProgress ? 9 * 60 * 1000 : 0,
      playedPercentage: i == inProgress ? 37.5 : null,
    ),
];

const List<String> _episodeTitles = <String>[
  '執事、腕利き',
  '執事、万能',
  '執事、最強',
  '執事、酔狂',
  '執事、邂逅',
  '執事、葬送',
  '執事、外出',
  '執事、訓練',
  '執事、幻影',
  '執事、氷上',
  '執事、如何様',
  '執事、閃く',
];

const List<String> _movieNames = <String>[
  '最終楽章 響け！ユーフォニアム 前編',
  '昆虫总动员2：来自远方的后援军',
  '雪孩子',
  'The Last Unicorn',
  '鹿铃',
  '小熊猫学木匠',
  '小八戒',
  '松鼠理发师',
  '午夜之眼2',
  '银河英雄传说 剧场版3 新战争的序曲',
  '银河英雄传说 剧场版2 黄金之翼',
  '小和尚之游方僧',
  '日月潭',
  '爱丽丝梦游仙境',
  '星际宝贝2：史迪奇有问题',
  'Robots',
  'Monsters, Inc.',
  '千与千寻',
  '龙猫',
  '天空之城',
  '魔女宅急便',
  '红猪',
  '幽灵公主',
  '哈尔的移动城堡',
];

const List<String> _seriesNames = <String>[
  '黑执事',
  '炎炎消防队',
  '黄泉的使者',
  '少女怪兽焦糖味',
  '尼古喵喵',
  '沧元图',
  '大主宰',
  '躲在超市后门抽烟的两人',
  '文豪野犬',
  'BLEACH 千年血戦篇',
  '無職転生 III',
  '幼女戦記 II',
  'BLACK TORCH',
  'ヤニねこ',
  '追放された転生重騎士',
  '乙女怪獣キャラメリゼ',
  '怪物：丽兹·波顿的故事',
  '生化危机：爆发夜',
  '逃出绝命街',
  '进击的巨人',
  '鬼灭之刃',
  '咒术回战',
  '我的英雄学院',
  '间谍过家家',
];

_PreviewBrowser _emby() {
  final _PreviewBrowser b = _PreviewBrowser(
    serverId: 'jellyfin:https://v1.uhdnow.com|u1',
    displayName: 'My Emby',
    serverUrl: 'https://v1.uhdnow.com',
  );
  b.libraries.addAll(const <MediaServerLibrary>[
    MediaServerLibrary(
      id: 'lib-cn-movies',
      name: '华语电影',
      kind: MediaServerLibraryKind.movies,
      hasCover: true,
    ),
    MediaServerLibrary(
      id: 'lib-anime',
      name: '动漫剧集',
      kind: MediaServerLibraryKind.tvShows,
      hasCover: true,
    ),
    MediaServerLibrary(
      id: 'lib-anime-movies',
      name: '动画电影',
      kind: MediaServerLibraryKind.movies,
      hasCover: true,
    ),
    MediaServerLibrary(
      id: 'lib-us-shows',
      name: '欧美剧集',
      kind: MediaServerLibraryKind.tvShows,
      hasCover: true,
    ),
    MediaServerLibrary(
      id: 'lib-variety',
      name: '综艺节目',
      kind: MediaServerLibraryKind.mixed,
      hasCover: true,
    ),
    // BUG-2602 的两种回退形态：uhdnow 那种「声称有图、端点 404」与 Jellyfin
    // 那种「库本来就没配封面」，都应画成条目海报拼贴。
    MediaServerLibrary(
      id: 'lib-cn-anime',
      name: '国产动漫',
      kind: MediaServerLibraryKind.tvShows,
      hasCover: true,
    ),
    MediaServerLibrary(
      id: 'lib-new',
      name: '追新',
      kind: MediaServerLibraryKind.tvShows,
    ),
  ]);
  b.children['lib-cn-anime'] = <MediaServerItem>[
    for (int i = 5; i < 9; i++) _series('cn-$i', _seriesNames[i], year: 2021),
  ];
  b.children['lib-new'] = <MediaServerItem>[
    for (int i = 10; i < 12; i++) _series('nw-$i', _seriesNames[i], year: 2026),
  ];
  b.children['lib-anime-movies'] = <MediaServerItem>[
    for (int i = 0; i < _movieNames.length; i++)
      _movie('am-$i', _movieNames[i], year: 1985 + i, rating: 6 + (i % 4)),
  ];
  b.children['lib-cn-movies'] = <MediaServerItem>[
    for (int i = 0; i < 12; i++)
      _movie(
        'cm-$i',
        _movieNames[(i + 5) % _movieNames.length],
        year: 2001 + i,
      ),
  ];
  b.children['lib-anime'] = <MediaServerItem>[
    for (int i = 0; i < _seriesNames.length; i++)
      _series(
        'sr-$i',
        _seriesNames[i],
        year: 2008 + i,
        unplayed: i % 3 == 0 ? 12 - i % 12 : null,
        childCount: 24,
        rating: 7.4,
      ),
  ];
  b.children['lib-us-shows'] = <MediaServerItem>[
    for (int i = 16; i < 20; i++) _series('us-$i', _seriesNames[i], year: 2019),
  ];
  b.children['lib-variety'] = <MediaServerItem>[
    for (int i = 0; i < 6; i++) _movie('va-$i', '综艺 ${i + 1}', year: 2024),
  ];
  // 黑执事：3 季，第 1 季 12 集，看到第 4 集，第 5 集看了一半；有标题 logo
  // （hero 走 logo 路径），电影详情无 logo（走文字大标题路径），两条都能看到。
  b.details['sr-0'] = _series(
    'sr-0',
    '黑执事',
    year: 2008,
    childCount: 3,
    episodeCount: 36,
    rating: 7.4,
    hasLogo: true,
    overview:
        '时值19世纪，在英国名门贵族凡多姆海伍家，有一位神秘、优雅、十全十美的执事，他就是"黑执事"塞巴斯蒂安。'
        '虽然塞巴斯蒂安总是淡淡地说："我只是一名执事罢了"，但举止、知识、品味、料理、武术等等没有任何事能难得倒他！'
        '塞巴斯蒂安的主人，是年仅12岁就位居凡多姆海伍家族的当主——夏尔。',
    genres: const <String>['动画', '悬疑', '奇幻'],
  );
  b.seasons['sr-0'] = <MediaServerItem>[
    for (int s = 1; s <= 3; s++)
      MediaServerItem(
        id: 'sr-0-s$s',
        name: '第 $s 季',
        type: MediaServerItemType.season,
        seriesId: 'sr-0',
        seriesName: '黑执事',
        seasonNumber: s,
        childCount: 12,
        hasCover: true,
      ),
  ];
  for (int s = 1; s <= 3; s++) {
    b.episodes['sr-0|sr-0-s$s'] = _episodes(
      seriesId: 'sr-0',
      seriesName: '黑执事',
      seasonId: 'sr-0-s$s',
      season: s,
      count: 12,
      playedUpTo: s == 1 ? 4 : 0,
      inProgress: s == 1 ? 5 : -1,
    );
  }
  b.details['am-14'] = _movie(
    'am-14',
    '星际宝贝2：史迪奇有问题',
    year: 2005,
    minutes: 68,
    rating: 6.7,
    overview:
        '星际宝贝史迪奇终于获得正式允许，从此跟小女孩莉萝住在夏威夷一同生活，莉萝想要参加一年一度的草裙舞大赛，'
        '以此来延续母亲过去的光荣事迹，史迪奇也在一旁帮助莉萝准备参赛，但没多久却发生了怪事。',
    genres: const <String>['动画', '喜剧', '家庭', '科幻'],
  );
  b.resume.addAll(<MediaServerItem>[
    b.episodes['sr-0|sr-0-s1']![4],
    _movie(
      'am-14',
      '星际宝贝2：史迪奇有问题',
      year: 2005,
      minutes: 68,
      positionMs: 31 * 60 * 1000,
    ),
    _movie('am-3', 'The Last Unicorn', year: 1982, positionMs: 12 * 60 * 1000),
  ]);
  b.nextUp.addAll(<MediaServerItem>[
    _episodes(
      seriesId: 'sr-1',
      seriesName: '炎炎消防队',
      seasonId: 'sr-1-s3',
      season: 3,
      count: 8,
    )[2],
    _episodes(
      seriesId: 'sr-9',
      seriesName: 'BLEACH 千年血戦篇',
      seasonId: 'sr-9-s2',
      season: 2,
      count: 13,
    )[6],
  ]);
  b.latest.addAll(<MediaServerItem>[
    ...b.children['lib-anime']!.take(5),
    ...b.children['lib-anime-movies']!.take(3),
  ]);
  return b;
}

_PreviewBrowser _homeJellyfin() {
  final _PreviewBrowser b = _PreviewBrowser(
    serverId: 'jellyfin:http://192.168.9.5:8096|u2',
    displayName: '家里的 Jellyfin',
    serverUrl: 'http://192.168.9.5:8096',
  );
  b.libraries.add(
    const MediaServerLibrary(
      id: 'h-anime',
      name: '番剧',
      kind: MediaServerLibraryKind.tvShows,
    ),
  );
  b.children['h-anime'] = <MediaServerItem>[
    for (int i = 19; i < 24; i++) _series('h-$i', _seriesNames[i], year: 2013),
  ];
  return b;
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
    final File out = File('$_outDir/$name.png');
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

Widget _harness(
  GlobalKey key,
  Widget body, {
  Size size = const Size(1600, 900),
}) {
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
          child: Scaffold(body: body),
        ),
      ),
    ),
  );
}

void _setView(WidgetTester tester, Size logical, double dpr) {
  tester.view.physicalSize = logical * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  // 像素预览只在 FUSHI_PREVIEW=1 时跑（见文件头）。
  final bool skip = Platform.environment['FUSHI_PREVIEW'] != '1';
  late Directory coverDir;

  setUpAll(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    coverDir = Directory.systemTemp.createTempSync('fushi-preview-covers');
  });

  // 每条测试重新注入：[RemoteCoverCache] 把目录 Future 记忆在首次调用的测试
  // FakeAsync zone 里，后面的测试 `await` 它时微任务排进已结束的 zone、永远不回
  // ——第二条起所有未进内存缓存的封面都卡在读盘前，画面只剩上一条测试加载过的
  // 那几张。debugSetDirResolver 顺带清掉记忆，目录本身仍共用（读盘缓存照常命中）。
  setUp(() {
    RemoteCoverCache.debugSetDirResolver(() async => coverDir);
  });

  tearDownAll(() {
    RemoteCoverCache.debugSetDirResolver(null);
    coverDir.deleteSync(recursive: true);
  });

  for (final (String tag, Size size, double dpr) in <(String, Size, double)>[
    ('desktop', const Size(1600, 900), 1.0),
    ('mobile', const Size(390, 844), 2.0),
  ]) {
    testWidgets('01 服务器列表 · $tag', (WidgetTester tester) async {
      _setView(tester, size, dpr);
      await tester.runAsync(_loadFont);
      final GlobalKey key = GlobalKey();
      await tester.pumpWidget(
        _harness(
          key,
          MediaServerListView(
            loadServers: () async => <MediaServerEntry>[
              MediaServerEntry(browser: _emby(), accountName: 'wight'),
              MediaServerEntry(browser: _homeJellyfin(), accountName: 'wight'),
            ],
            play: (BuildContext _, MediaServerPlayRequest __) {},
            onOpenSettings: () {},
          ),
          size: size,
        ),
      );
      await _settleWithImages(tester);
      await _capture(tester, key, '01_servers_$tag');
    }, skip: skip);

    testWidgets('02 服务器首页 · $tag', (WidgetTester tester) async {
      _setView(tester, size, dpr);
      await tester.runAsync(_loadFont);
      final GlobalKey key = GlobalKey();
      await tester.pumpWidget(
        _harness(
          key,
          MediaServerHomeView(
            session: MediaServerSession(
              browser: _emby(),
              play: (BuildContext _, MediaServerPlayRequest __) {},
            ),
            showBackButton: true,
          ),
          size: size,
        ),
      );
      await _settleWithImages(tester);
      await _capture(tester, key, '02_home_$tag');
    }, skip: skip);

    testWidgets('03 库网格 · $tag', (WidgetTester tester) async {
      _setView(tester, size, dpr);
      await tester.runAsync(_loadFont);
      final GlobalKey key = GlobalKey();
      await tester.pumpWidget(
        _harness(
          key,
          MediaServerGridView(
            session: MediaServerSession(
              browser: _emby(),
              play: (BuildContext _, MediaServerPlayRequest __) {},
            ),
            parentId: 'lib-anime',
            title: '动漫剧集',
          ),
          size: size,
        ),
      );
      await _settleWithImages(tester);
      await _capture(tester, key, '03_grid_$tag');
    }, skip: skip);

    testWidgets('04 剧详情 · $tag', (WidgetTester tester) async {
      _setView(tester, size, dpr);
      await tester.runAsync(_loadFont);
      final GlobalKey key = GlobalKey();
      final _PreviewBrowser browser = _emby();
      await tester.pumpWidget(
        _harness(
          key,
          MediaServerDetailView(
            session: MediaServerSession(
              browser: browser,
              play: (BuildContext _, MediaServerPlayRequest __) {},
            ),
            item: browser.children['lib-anime']!.first,
          ),
          size: size,
        ),
      );
      await _settleWithImages(tester);
      await _capture(tester, key, '04_series_detail_$tag');
      // hero 就占满首屏的六成，集卡网格在折叠线以下：再滚一屏单独抓一张，
      // 集卡的缩略图 / 序号 / 时长 / 已看勾 / 续播高亮才看得见。
      await tester.drag(
        find.byType(CustomScrollView),
        Offset(0, -(size.height * 0.85)),
      );
      await _settleWithImages(tester);
      await _capture(tester, key, '04_series_detail_${tag}_episodes');
    }, skip: skip);

    testWidgets('05 电影详情 · $tag', (WidgetTester tester) async {
      _setView(tester, size, dpr);
      await tester.runAsync(_loadFont);
      final GlobalKey key = GlobalKey();
      final _PreviewBrowser browser = _emby();
      await tester.pumpWidget(
        _harness(
          key,
          MediaServerDetailView(
            session: MediaServerSession(
              browser: browser,
              play: (BuildContext _, MediaServerPlayRequest __) {},
            ),
            item: browser.children['lib-anime-movies']![14],
          ),
          size: size,
        ),
      );
      await _settleWithImages(tester);
      await _capture(tester, key, '05_movie_detail_$tag');
    }, skip: skip);
  }
}
