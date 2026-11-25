import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/floating_ball/screen_ocr_card_image.dart';
import 'package:fushi/src/lookup/effective_lookup_size.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/popup_dictionary_page.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:image/image.dart' as img;

import '../helpers/popup_mining_target_overrides.dart';
import '../helpers/test_platform_services.dart';

/// 截屏识字制卡带图的接线（反馈 Gz7z6Y6Mbr / mOe5HjBtuG）：真 [PopupDictionaryPage]
/// （[DictionaryPageMixin] 的截屏识字宿主）+ 假 Anki 仓库，锁住
///   - 高级制卡对话框写进 fields 的覆盖项（框选 / 不要图）真的传到出卡图那一步，
///     一键「+」（没有覆盖项）仍是自动裁切；覆盖已制的卡（onUpdateEntry）同一条路；
///   - 偏好「截屏识字制卡带截图」关着 / 没有卡图来源时，高级制卡不出图片分区、卡上不带图；
///   - Android 定格帧文件在查词窗打开后被下一次截屏删掉，这张卡照样带图。
class _CardImageAppModel extends AppModel {
  _CardImageAppModel() : super(testPlatformServices());

  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];

  @override
  bool get isInitialised => true;

  @override
  Future<bool> refreshPrefCacheIfChanged() async => false;

  @override
  Future<bool> refreshForWarmDictionaryPopup() async => false;

  @override
  ThemeData get theme => ThemeData.light();

  @override
  ThemeData get darkTheme => ThemeData.dark();

  @override
  ThemeMode get themeMode => ThemeMode.light;

  @override
  bool get lowMemoryMode => false;

  @override
  int get maximumTerms => 10;

  @override
  double get popupMaxWidth => 400;

  @override
  LookupSize get overlayLookupEffectiveSize =>
      LookupSize(popupMaxWidth, kLookupPopupDefaultHeight);

  @override
  double get dictionaryFontSize => 16;

  @override
  double get appUiScale => 1.0;

  @override
  List<String> get enabledAudioSources => const <String>[];

  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}

  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}

  @override
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async => DictionarySearchResult(searchTerm: searchTerm);
}

/// 制卡时卡图（[AnkiMiningContext.coverPath]）的像素尺寸；没带图为 null。制卡一结束
/// 宿主就删卡图临时目录，所以必须在仓库收到请求的那一刻读。
typedef _Cover = ({int width, int height})?;

class _RecordingAnkiRepo extends BaseAnkiRepository {
  final List<_Cover> mined = <_Cover>[];
  final List<_Cover> updated = <_Cover>[];

  static _Cover _coverOf(AnkiMiningContext context) {
    final String? path = context.coverPath;
    if (path == null) return null;
    final img.Image card = img.decodeImage(File(path).readAsBytesSync())!;
    return (width: card.width, height: card.height);
  }

  @override
  Future<AnkiSettings> loadSettings() async => AnkiSettings();

  @override
  Future<void> saveSettings(AnkiSettings s) async {}

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    mined.add(_coverOf(context));
    return MineOutcome.failure('recorded');
  }

  @override
  Future<MineOutcome> updateMinedNote({
    required int noteId,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    updated.add(_coverOf(context));
    return MineOutcome.failure('recorded');
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createDeck(String name) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;
}

Uint8List _whitePng(int width, int height) {
  final img.Image page = img.Image(width: width, height: height);
  img.fill(page, color: img.ColorRgb8(255, 255, 255));
  return img.encodePng(page);
}

// 1200×800 截图；文本块 (100,100)-(700,300)，行粗 40 → 留白 60 → 自动框
// (40,40)-(760,360) = 720×320（宽高比 2.25）。
const Rect _textBlock = Rect.fromLTRB(100, 100, 700, 300);
const Rect _line = Rect.fromLTRB(100, 100, 700, 140);
const double _autoAspect = 720 / 320;

/// 对话框里框的左上四分之一：600×400（宽高比 1.5），与自动框分得开。
const MiningImageCrop _quarterCrop = MiningImageCrop(
  pageIndex: kScreenOcrCardCropPageIndex,
  left: 0,
  top: 0,
  right: 0.5,
  bottom: 0.5,
);

double _aspect(_Cover cover) => cover!.width / cover.height;

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late _CardImageAppModel appModel;
  late _RecordingAnkiRepo repo;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    appModel = _CardImageAppModel()..wirePreferencesForTesting(prefs);
    repo = _RecordingAnkiRepo();
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpPopup(
    WidgetTester tester,
    ScreenOcrCardImage? source,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appProvider.overrideWith((ref) => appModel),
          ankiRepositoryProvider.overrideWithValue(repo),
          ...popupMiningTargetTestOverrides(anki: false),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: appModel.navigatorKey,
            home: PopupDictionaryPage(
              searchTerm: '吾輩は猫である',
              sourceCharIndex: 0,
              cardImage: source,
              closeInApp: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  DictionaryPopupLayer baseLayer(WidgetTester tester) =>
      tester.widget(find.byType(DictionaryPopupLayer).first);

  DictionaryPageMixin host(WidgetTester tester) =>
      tester.state(find.byType(PopupDictionaryPage)) as DictionaryPageMixin;

  Map<String, String> fieldsWith(MiningRequestOverrides? overrides) {
    final Map<String, String> fields = <String, String>{
      'expression': '猫',
      'sentence': '',
    };
    return overrides == null
        ? fields
        : MiningRequestOverrides.attach(fields, overrides);
  }

  Future<void> mine(WidgetTester tester, Map<String, String> fields) async {
    await tester.runAsync(() => baseLayer(tester).onMineEntry!(fields));
  }

  ScreenOcrCardImage memorySource() => ScreenOcrCardImage(
    bytes: _whitePng(1200, 800),
    textBlock: _textBlock,
    line: _line,
  );

  group('高级制卡覆盖项传到出卡图', () {
    testWidgets('一键「+」没有覆盖项：自动裁到文本块', (WidgetTester tester) async {
      await pumpPopup(tester, memorySource());
      await mine(tester, fieldsWith(null));
      expect(repo.mined, hasLength(1));
      expect(_aspect(repo.mined.single), closeTo(_autoAspect, 0.02));
    });

    testWidgets('对话框里框选了：卡图按框裁，不是自动框', (WidgetTester tester) async {
      await pumpPopup(tester, memorySource());
      await mine(
        tester,
        fieldsWith(const MiningRequestOverrides(crop: _quarterCrop)),
      );
      expect(repo.mined, hasLength(1));
      expect(_aspect(repo.mined.single), closeTo(1.5, 0.02));
    });

    testWidgets('对话框里选了「不要图」：卡上不带图', (WidgetTester tester) async {
      await pumpPopup(tester, memorySource());
      await mine(
        tester,
        fieldsWith(const MiningRequestOverrides(omitImage: true)),
      );
      expect(repo.mined, <_Cover>[null]);
    });

    testWidgets('覆盖已制的卡（onUpdateEntry）同样按框裁', (WidgetTester tester) async {
      await pumpPopup(tester, memorySource());
      await tester.runAsync(
        () => baseLayer(tester).onUpdateEntry!(
          42,
          fieldsWith(const MiningRequestOverrides(crop: _quarterCrop)),
        ),
      );
      expect(repo.updated, hasLength(1));
      expect(_aspect(repo.updated.single), closeTo(1.5, 0.02));
    });
  });

  group('偏好与来源决定有没有图片分区 / 卡图', () {
    testWidgets('偏好开着、有来源：高级制卡给截图裁切分区', (WidgetTester tester) async {
      await pumpPopup(tester, memorySource());
      final AdvancedMiningSections sections =
          await tester.runAsync(
                // ignore: invalid_use_of_protected_member
                () => host(tester).buildAdvancedMiningSections(matched: '猫'),
              )
              as AdvancedMiningSections;
      expect(sections.mangaImage, isNotNull);
      expect(sections.mangaImage!.source, AdvancedMiningCropSource.screenshot);
    });

    testWidgets('偏好关着：没有图片分区，一键「+」也不带图', (WidgetTester tester) async {
      await prefs.setScreenOcrCardImage(false);
      await pumpPopup(tester, memorySource());
      final AdvancedMiningSections sections =
          await tester.runAsync(
                // ignore: invalid_use_of_protected_member
                () => host(tester).buildAdvancedMiningSections(matched: '猫'),
              )
              as AdvancedMiningSections;
      expect(identical(sections, AdvancedMiningSections.none), isTrue);
      await mine(tester, fieldsWith(null));
      expect(repo.mined, <_Cover>[null]);
    });

    testWidgets('没有卡图来源（非截屏识字入口）：没有图片分区', (WidgetTester tester) async {
      await pumpPopup(tester, null);
      final AdvancedMiningSections sections =
          await tester.runAsync(
                // ignore: invalid_use_of_protected_member
                () => host(tester).buildAdvancedMiningSections(matched: '猫'),
              )
              as AdvancedMiningSections;
      expect(identical(sections, AdvancedMiningSections.none), isTrue);
    });
  });

  testWidgets('查词窗一收到卡图来源就先读进内存；常驻热页换了来源再读新的', (WidgetTester tester) async {
    // Android 定格帧文件只活到下一次截屏：必须在用户点「+」/ 高级制卡之前就读到。
    // 读到之后文件被清掉也照样出图，由 screen_ocr_card_image_test 的缓存用例锁住。
    final _CountingSource first = _CountingSource();
    await pumpPopup(tester, first);
    expect(first.reads, 1, reason: '打开查词窗就预读，不等到制卡');
    final _CountingSource second = _CountingSource();
    await pumpPopup(tester, second);
    expect(second.reads, 1, reason: '同一常驻页（didUpdateWidget）换了来源也预读');
    expect(first.reads, 1);
  });
}

/// 记下 [readBytes] 被调了几次的卡图来源。
class _CountingSource extends ScreenOcrCardImage {
  _CountingSource()
    : super(bytes: _whitePng(4, 4), textBlock: _textBlock, line: _line);

  int reads = 0;

  @override
  Future<Uint8List?> readBytes() {
    reads++;
    return super.readBytes();
  }
}
