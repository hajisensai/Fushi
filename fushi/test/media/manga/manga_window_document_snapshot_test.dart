// manga-13：改阅读器设置时，只有真正改到窗口文档的项才重载文档。
//
// 判定口径：拿装载那一刻的导航输入、配当前设置重建一份文档，与屏上那份逐字比较。
// 这里用真实的 mangaWindowDocument 当生成器，钉住三件事：
// 1. 不进文档的项（常亮 / 音量键 / 反转音量键 / 全屏）改了 → 判定「没变」，不重载；
// 2. 进文档的视觉项（缩放方式 / 裁边 / 底色 / 识别范围）改了 → 判定「变了」；
// 3. 装载后在文档内翻页 / 滚动 / 捏合（导航输入推进）不影响判定——拿当前导航
//    现建一份去比必然不同，那样等于永远重载，修复就白做了。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/reader/manga_window_document_snapshot.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

const List<MokuroImage> _pages = <MokuroImage>[
  MokuroImage(
    url: 'p0.jpg',
    size: MokuroSize(1000, 1500),
    blocks: <MokuroBlock>[],
  ),
  MokuroImage(
    url: 'p1.jpg',
    size: MokuroSize(1000, 1500),
    blocks: <MokuroBlock>[],
  ),
  MokuroImage(
    url: 'p2.jpg',
    size: MokuroSize(1000, 1500),
    blocks: <MokuroBlock>[],
  ),
  MokuroImage(
    url: 'p3.jpg',
    size: MokuroSize(1000, 1500),
    blocks: <MokuroBlock>[],
  ),
];

/// 模拟阅读器页：设置是可变状态，导航输入由调用方给（与页面里
/// `_buildWindowDocument` 的分工一致）。
class _ReaderState {
  MangaReaderPreferences preferences = const MangaReaderPreferences();
  MangaReadingMode mode = MangaReadingMode.spread;
  String background = '#000';

  String build(MangaWindowNavigation navigation) => mangaWindowDocument(
    _pages,
    <String>[for (final MokuroImage page in _pages) page.url],
    mode: mode,
    spreadDirection: 'rtl',
    inlineSelectionJs: '',
    pageSpreadIndices: const <int>[0, 1, 2, 3],
    pagesPerSpread: const <int>[1, 1, 1, 1],
    currentSpread: navigation.currentSpread,
    restoreFraction: navigation.restoreFraction,
    zoomPercent: navigation.zoomPercent,
    documentGeneration: navigation.documentGeneration,
    readerPreferences: preferences,
    backgroundCss: background,
  );
}

MangaWindowNavigation _nav({
  int generation = 1,
  int spread = 0,
  double fraction = 0,
  int zoom = 100,
}) => MangaWindowNavigation(
  documentGeneration: generation,
  currentSpread: spread,
  restoreFraction: fraction,
  zoomPercent: zoom,
);

void main() {
  late _ReaderState state;
  late MangaWindowDocumentSnapshot snapshot;

  setUp(() {
    state = _ReaderState();
    snapshot = MangaWindowDocumentSnapshot();
    final MangaWindowNavigation loaded = _nav();
    snapshot.record(state.build(loaded), loaded);
  });

  test('不进文档的设置（常亮 / 音量键 / 反转音量键 / 全屏）改了不判为需重载', () {
    state.preferences = state.preferences.copyWithJson(<String, Object?>{
      'keepScreenOn': !state.preferences.keepScreenOn,
      'volumeKeys': !state.preferences.volumeKeys,
      'invertVolumeKeys': !state.preferences.invertVolumeKeys,
      'fullscreen': !state.preferences.fullscreen,
    });
    expect(snapshot.matches(state.build), isTrue);
  });

  test('进文档的视觉项改了判为需重载', () {
    final MangaReaderPreferences base = state.preferences;
    for (final Map<String, Object?> change in <Map<String, Object?>>[
      <String, Object?>{'scaleType': 'fit_width'},
      <String, Object?>{'cropBorders': !base.cropBorders},
      <String, Object?>{'showOcrBoxes': !base.showOcrBoxes},
      <String, Object?>{'invertColors': !base.invertColors},
    ]) {
      state.preferences = base.copyWithJson(change);
      expect(
        snapshot.matches(state.build),
        isFalse,
        reason: '$change 编进窗口文档，必须重载才生效',
      );
    }
    state.preferences = base;
    state.background = '#fff';
    expect(snapshot.matches(state.build), isFalse, reason: '底色编进文档');
  });

  test('画质缩放 / Gamma 校正编进文档（FIT_STEP / FIT_HQ），切换后判为需重载', () {
    // #3843 × manga-13：页图 URL 上的 `fq=` 与取整档距是生成文档时写进 JS 常量的，
    // 改这两个开关不重载文档的话，屏上页图仍按旧画质档请求，开关形同虚设。
    final MangaReaderPreferences base = state.preferences;
    expect(base.enhancedScaling, isTrue, reason: '前提：画质缩放默认开');
    expect(state.build(_nav()), contains("var FIT_HQ = '&fq=1';"));

    state.preferences = base.copyWithJson(<String, Object?>{
      'enhancedScaling': false,
    });
    expect(snapshot.matches(state.build), isFalse);
    expect(state.build(_nav()), contains("var FIT_HQ = '';"));
    expect(state.build(_nav()), contains('var FIT_STEP = 128;'));

    state.preferences = base.copyWithJson(<String, Object?>{
      'gammaCorrectScaling': true,
    });
    expect(snapshot.matches(state.build), isFalse);
    expect(state.build(_nav()), contains("var FIT_HQ = '&fq=g';"));

    // 画质缩放关着时 Gamma 校正不起作用：文档逐字不变，不白重载。
    final MangaWindowNavigation loaded = _nav();
    state.preferences = base.copyWithJson(<String, Object?>{
      'enhancedScaling': false,
    });
    snapshot.record(state.build(loaded), loaded);
    state.preferences = state.preferences.copyWithJson(<String, Object?>{
      'gammaCorrectScaling': true,
    });
    expect(snapshot.matches(state.build), isTrue);
  });

  test('装载后文档内翻页 / 滚动 / 捏合不影响判定', () {
    // 页面里这几项在 JS 推进后同步回 Dart，现建文档会带上新值。
    final MangaWindowNavigation moved = _nav(
      generation: 1,
      spread: 3,
      fraction: 0.6,
      zoom: 180,
    );
    expect(
      state.build(moved) == state.build(_nav()),
      isFalse,
      reason: '前提：导航输入确实进文档，拿当前导航现建一份去比必然不同',
    );
    state.preferences = state.preferences.copyWithJson(<String, Object?>{
      'keepScreenOn': !state.preferences.keepScreenOn,
    });
    expect(
      snapshot.matches(state.build),
      isTrue,
      reason: '判定必须用装载时的导航输入重建，否则任何设置变更都会重载',
    );
  });

  test('没有确知文档（装载中 / WebView 重建 / 销毁）时一律判为需重载', () {
    snapshot.invalidate();
    expect(snapshot.hasDocument, isFalse);
    expect(snapshot.matches(state.build), isFalse);
  });

  test('阅读模式改了判为需重载', () {
    state.mode = MangaReadingMode.webtoon;
    expect(snapshot.matches(state.build), isFalse);
  });
}
