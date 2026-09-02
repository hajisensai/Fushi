import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/effective_lookup_size.dart';
import 'package:fushi/src/lookup/gal_ingame_lookup_controller.dart';
import 'package:fushi/src/lookup/global_lookup_channel.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/lookup/overlay_window_channel.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-2058 / BUG-2057 —— 游戏内查词卡的**尺寸上界**与**布局工作区**。
///
/// 为什么必须有这个文件：这两条修复此前一条测试都没有。把 `_applyCardSizeCap` 里
/// 「按客户区算上界」整段撤销，`test/lookup` 719 条**一条都不红**（实测）；把
/// `_effectiveLookupSizeForCurrentRoute` 的 galCard 分支改回共读 overlay 键，同样
/// 719 条全绿。原因是既有覆盖全落在纯函数（`effectiveLookupSize`、`computeFrameRect`）
/// 和 wire 透传上，**分流接线本身**没有任何咬合点。
///
/// 三条不变式：
/// 1. 卡片尺寸上界按**游戏客户区物理像素**算，而且**本局第一次查词就要按它算**
///    ——客户区随每条 hit 现量现报（[GalLookupHit.clientW]），不是等 present 回执
///    才知道的会话级缓存。缓存版本的症状是每局第一次查词原样复发旧 bug。
/// 2. 上界同时受**画布**约束：卡片可能落到位图回退路径被 1:1 画进 primaryLayer，
///    比画布还大的位图会被静默裁掉下半截。
/// 3. 布局工作区（workWidth/Height）必须与根卡原点（workOriginX/Y）**同域**。
///    原点在画布坐标系里解出来，所以工作区也只能是画布尺寸；换成客户区尺寸会让
///    级联子卡的 spaceRight/spaceBelow 判定系统性偏乐观。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  // 真机实测形态（BUG-2058）：KiriKiri 画布 1280x720 被放大进 1902x1069 客户区。
  const int kCanvasW = 1280;
  const int kCanvasH = 720;
  const int kClientW = 1902;
  const int kClientH = 1069;

  GalLookupHit hitOf({
    required int viewW,
    required int viewH,
    int clientW = 0,
    int clientH = 0,
  }) => GalLookupHit(
    seq: 1,
    line: '永遠',
    providerKind: 1,
    providerId: 1,
    charIndex: 0,
    sourceLength: 1,
    charCount: 2,
    textGeneration: 1,
    geometryGeneration: 1,
    // 2 = PrimaryLayer：唯一一个 view 域 != 客户区域的坐标域（KiriKiri）。
    coordinateSpace: 2,
    writingMode: 1,
    glyphX: 400,
    glyphY: 600,
    glyphW: 24,
    glyphH: 24,
    viewW: viewW,
    viewH: viewH,
    clientW: clientW,
    clientH: clientH,
    submit: true,
  );

  final GalIngameLookupController gal = GalIngameLookupController.test();

  tearDown(() {
    GlobalLookupController.instance.setPhysicalCap();
  });

  group('卡片尺寸上界', () {
    test('本局第一次查词就按客户区口径出卡（不必先跑一次 present）', () {
      // 全新控制器、零 present 回执——这正是"每局第一次查词"的状态。
      gal.debugApplyCardSizeCap(
        hitOf(
          viewW: kCanvasW,
          viewH: kCanvasH,
          clientW: kClientW,
          clientH: kClientH,
        ),
      );
      final ({int w, int h})? cap =
          GlobalLookupController.instance.debugPhysicalCap;
      expect(cap, isNotNull);
      // 0.6 x 1069 = 641.4 -> 641。旧的画布口径是 0.6 x 720 = 432，
      // 也正是"用户把最大高度调多大都不生效"的那个数。
      expect(cap!.h, 641, reason: '第一次查词就必须按客户区高算；432 = 退回画布口径 = BUG-2058 复发');
      expect(cap.w, 1141, reason: '0.6 x 1902 = 1141.2 -> 1141');
    });

    test('客户区变化立刻跟上（全屏↔窗口化不会读到上一次的旧值）', () {
      gal.debugApplyCardSizeCap(
        hitOf(
          viewW: kCanvasW,
          viewH: kCanvasH,
          clientW: kClientW,
          clientH: kClientH,
        ),
      );
      expect(GlobalLookupController.instance.debugPhysicalCap!.h, 641);

      // 玩家把窗口缩回原生尺寸：**同一局**，只是下一条 hit。
      gal.debugApplyCardSizeCap(
        hitOf(
          viewW: kCanvasW,
          viewH: kCanvasH,
          clientW: kCanvasW,
          clientH: kCanvasH,
        ),
      );
      final ({int w, int h}) cap =
          GlobalLookupController.instance.debugPhysicalCap!;
      expect(cap.h, 432, reason: '缓存版本会留在 641：cap > 当前客户区，卡片原点被夹到 0、整张盖住画面');
      expect(cap.w, 768);
    });

    test('量不到客户区（clientW/H == 0）时退回画布口径，不拿 0 当尺寸', () {
      gal.debugApplyCardSizeCap(hitOf(viewW: kCanvasW, viewH: kCanvasH));
      final ({int w, int h}) cap =
          GlobalLookupController.instance.debugPhysicalCap!;
      expect(cap.w, 768);
      expect(cap.h, 432);
    });

    test('上界同时受画布约束：位图回退路径不会算出比画布还大的卡片', () {
      // 3 倍放大：0.6 x 3840 = 2304、0.6 x 2160 = 1296，两者都超出 1280x720 画布。
      // 位图回退是 1:1 画进 primaryLayer 的，超出部分会被静默裁掉。
      gal.debugApplyCardSizeCap(
        hitOf(viewW: kCanvasW, viewH: kCanvasH, clientW: 3840, clientH: 2160),
      );
      final ({int w, int h}) cap =
          GlobalLookupController.instance.debugPhysicalCap!;
      expect(cap.w, lessThanOrEqualTo(kCanvasW));
      expect(cap.h, lessThanOrEqualTo(kCanvasH));
      expect(cap.w, kCanvasW);
      expect(cap.h, kCanvasH);
    });

    test('画布口径的裁剪不会反过来压掉真机那一档的收益', () {
      // scale = 1.486 < 1/0.6，所以画布约束在真机形态下**不该**咬到：
      // 若把 min 写反（拿画布口径当上界），这里会退回 432。
      gal.debugApplyCardSizeCap(
        hitOf(
          viewW: kCanvasW,
          viewH: kCanvasH,
          clientW: kClientW,
          clientH: kClientH,
        ),
      );
      expect(GlobalLookupController.instance.debugPhysicalCap!.h, 641);
    });
  });

  group('布局工作区与根卡原点同域', () {
    test('workWidth/Height 是画布尺寸，与画布域的 workOrigin 同域', () {
      gal.debugApplyCardSizeCap(
        hitOf(
          viewW: kCanvasW,
          viewH: kCanvasH,
          clientW: kClientW,
          clientH: kClientH,
        ),
      );
      final ({int w, int h, int x, int y}) work =
          GlobalLookupController.instance.debugLayoutWorkArea!;
      expect(work.w, kCanvasW, reason: '换成客户区宽(1902)就与画布域的原点不同域了');
      expect(work.h, kCanvasH, reason: '换成客户区高(1069)同理');
    });

    test('根卡整张留在工作区内（域自洽的唯一可判据）', () {
      gal.debugApplyCardSizeCap(
        hitOf(
          viewW: kCanvasW,
          viewH: kCanvasH,
          clientW: kClientW,
          clientH: kClientH,
        ),
      );
      final ({int w, int h}) cap =
          GlobalLookupController.instance.debugPhysicalCap!;
      final ({int w, int h, int x, int y}) work =
          GlobalLookupController.instance.debugLayoutWorkArea!;
      // 原点是按 cap 大小夹进 view 的，所以 origin + cap <= work 必须成立。
      // 工作区一旦被换成更大的客户区尺寸，这条依然"成立"但不再有约束力——
      // 所以上一条测试的等值断言才是真正的门，这条只是补一层自洽。
      expect(work.x, greaterThanOrEqualTo(0));
      expect(work.y, greaterThanOrEqualTo(0));
      expect(work.x + cap.w, lessThanOrEqualTo(work.w));
      expect(work.y + cap.h, lessThanOrEqualTo(work.h));
    });

    test('view 非法时清空 cap 与工作区（不留上一次查词的残值）', () {
      gal.debugApplyCardSizeCap(
        hitOf(
          viewW: kCanvasW,
          viewH: kCanvasH,
          clientW: kClientW,
          clientH: kClientH,
        ),
      );
      expect(GlobalLookupController.instance.debugPhysicalCap, isNotNull);
      gal.debugApplyCardSizeCap(hitOf(viewW: 0, viewH: 0, clientW: kClientW));
      expect(GlobalLookupController.instance.debugPhysicalCap, isNull);
      expect(GlobalLookupController.instance.debugLayoutWorkArea, isNull);
    });
  });

  group('有效最大宽高按 route 分流', () {
    late Directory pathProviderDir;
    setUpAll(() {
      pathProviderDir = Directory.systemTemp.createTempSync(
        'hibiki_gal_cap_path_provider',
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async => pathProviderDir.path,
      );
    });
    tearDownAll(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      if (pathProviderDir.existsSync()) {
        pathProviderDir.deleteSync(recursive: true);
      }
    });

    late FushiDatabase db;
    late PreferencesRepository prefs;
    late AppModel appModel;

    setUp(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      appModel = AppModel(testPlatformServices());
      appModel.wireLocalAudioForTesting(
        prefsRepo: prefs,
        databaseDirectory: Directory.systemTemp.createTempSync('gal_cap_size'),
      );
    });

    tearDown(() async {
      prefs.dispose();
      await db.close();
    });

    test('galCard route 读 gal 键，桌面 route 读 overlay 键（两组值不互串）', () async {
      // 非对称、且两组之间也不对称：任何一条接错都会被下面的等值断言抓到。
      await prefs.setPref('gal_card_lookup_independent_size', true);
      await prefs.setPref('gal_card_lookup_max_width', 700.0);
      await prefs.setPref('gal_card_lookup_max_height', 900.0);
      await prefs.setPref('overlay_lookup_independent_size', true);
      await prefs.setPref('overlay_lookup_max_width', 500.0);
      await prefs.setPref('overlay_lookup_max_height', 650.0);

      const GlobalLookupRoute galRoute = GlobalLookupRoute.galCard(
        routeEpoch: 1,
        lookupEpoch: 1,
      );
      final LookupSize inGame = GlobalLookupChannel.runWithRoute(
        galRoute,
        () => GlobalLookupController.instance
            .debugEffectiveLookupSizeForCurrentRoute(appModel),
      );
      expect(
        inGame,
        const LookupSize(700.0, 900.0),
        reason: '共读 overlay 键会拿到 500x650——这正是 BUG-2058 ① 的形态',
      );

      const GlobalLookupRoute desktopRoute = GlobalLookupRoute.desktop();
      final LookupSize desktop = GlobalLookupChannel.runWithRoute(
        desktopRoute,
        () => GlobalLookupController.instance
            .debugEffectiveLookupSizeForCurrentRoute(appModel),
      );
      expect(
        desktop,
        const LookupSize(500.0, 650.0),
        reason: '桌面覆盖窗必须继续读 overlay 键，不能被 gal 那组反向污染',
      );
    });

    test('gal 开关关闭时跟随 app 内共享值，不误用已写入的独立宽高', () async {
      await prefs.setPref('gal_card_lookup_max_width', 1200.0);
      await prefs.setPref('gal_card_lookup_max_height', 1500.0);
      expect(appModel.galCardLookupIndependentSize, isFalse);

      const GlobalLookupRoute galRoute = GlobalLookupRoute.galCard(
        routeEpoch: 2,
        lookupEpoch: 2,
      );
      final LookupSize inGame = GlobalLookupChannel.runWithRoute(
        galRoute,
        () => GlobalLookupController.instance
            .debugEffectiveLookupSizeForCurrentRoute(appModel),
      );
      expect(
        inGame,
        LookupSize(appModel.popupMaxWidth, appModel.popupMaxHeight),
      );
    });
  });
}
