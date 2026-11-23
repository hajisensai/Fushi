import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/floating_ball/screen_ocr_card_frame.dart';
import 'package:fushi/src/floating_ball/screen_ocr_card_image.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

/// 拍板 EuOLprw_dV（选 b）：截屏识字「制卡时框选截图」——每次「+」先推出框选页，
/// 「制卡」按框出图，「×」不制这张卡。
void main() {
  Uint8List whitePng(int width, int height) {
    final img.Image page = img.Image(width: width, height: height);
    img.fill(page, color: img.ColorRgb8(255, 255, 255));
    return img.encodePng(page);
  }

  // 1200×800 截图；文本块 (100,100)-(700,300)，行粗 40 → 自动框 (40,40)-(760,360)。
  ScreenOcrCardImage source() => ScreenOcrCardImage(
    bytes: whitePng(1200, 800),
    textBlock: const Rect.fromLTRB(100, 100, 700, 300),
    line: const Rect.fromLTRB(100, 100, 700, 140),
  );

  group('screenOcrCardFrameNeeded', () {
    test('两个偏好都开、这次没带卡图选择 → 弹框选', () {
      expect(
        screenOcrCardFrameNeeded(
          cardImageEnabled: true,
          frameOnMine: true,
          overrides: null,
        ),
        isTrue,
      );
      // 只带了句子音频的调整（应用外查词卡「调整句子音频」）照样要框。
      expect(
        screenOcrCardFrameNeeded(
          cardImageEnabled: true,
          frameOnMine: true,
          overrides: const MiningRequestOverrides(audioStartDeltaMs: -300),
        ),
        isTrue,
      );
    });

    test('任一偏好关着 → 一键「+」照旧', () {
      expect(
        screenOcrCardFrameNeeded(
          cardImageEnabled: false,
          frameOnMine: true,
          overrides: null,
        ),
        isFalse,
      );
      expect(
        screenOcrCardFrameNeeded(
          cardImageEnabled: true,
          frameOnMine: false,
          overrides: null,
        ),
        isFalse,
      );
    });

    test('高级制卡里已经框过 / 选了「不要」→ 不再弹', () {
      expect(
        screenOcrCardFrameNeeded(
          cardImageEnabled: true,
          frameOnMine: true,
          overrides: const MiningRequestOverrides(
            crop: MiningImageCrop(
              pageIndex: kScreenOcrCardCropPageIndex,
              left: 0,
              top: 0,
              right: 1,
              bottom: 1,
            ),
          ),
        ),
        isFalse,
      );
      expect(
        screenOcrCardFrameNeeded(
          cardImageEnabled: true,
          frameOnMine: true,
          overrides: const MiningRequestOverrides(omitImage: true),
        ),
        isFalse,
      );
    });
  });

  test('mergeScreenOcrCardFrame：保留原有的句子音频调整，卡图三项以框选为准', () {
    const MiningRequestOverrides base = MiningRequestOverrides(
      audioStartDeltaMs: -300,
      audioEndDeltaMs: 200,
    );
    const MiningImageCrop crop = MiningImageCrop(
      pageIndex: kScreenOcrCardCropPageIndex,
      left: 0,
      top: 0,
      right: 1,
      bottom: 0.5,
    );
    final MiningRequestOverrides merged = mergeScreenOcrCardFrame(
      base,
      const MiningRequestOverrides(crop: crop),
    );
    expect(merged.audioStartDeltaMs, -300);
    expect(merged.audioEndDeltaMs, 200);
    expect(merged.crop?.bottom, 0.5);
    expect(merged.omitImage, isFalse);
    final ScreenOcrCardImagePlan plan = resolveScreenOcrCardImagePlan(merged);
    expect(plan.kind, ScreenOcrCardImageKind.crop);
    expect(plan.crop, const Rect.fromLTRB(0, 0, 1, 0.5));

    final MiningRequestOverrides omitted = mergeScreenOcrCardFrame(
      null,
      const MiningRequestOverrides(omitImage: true),
    );
    expect(
      resolveScreenOcrCardImagePlan(omitted).kind,
      ScreenOcrCardImageKind.omit,
    );
  });

  test('MinePopupResult.cancelled：不是失败、不带原因，popup.js 按 cancelled 放回「+」', () {
    const MinePopupResult result = MinePopupResult.cancelled();
    expect(result.accepted, isFalse);
    expect(result.toJson(), <String, Object?>{
      'ankiConnect': false,
      'noteId': null,
      'cancelled': true,
    });
    expect(const MinePopupResult().toJson().containsKey('cancelled'), isFalse);
  });

  test('popup.js：cancelled 回包放回「+」，不走失败提示', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();
    expect(js, contains('cancelled: reply.cancelled === true'));
    final int cancelled = js.indexOf('} else if (result.cancelled) {');
    final int failure = js.indexOf(
      'reportMineFailure(mineButton, result);',
      cancelled,
    );
    expect(cancelled, greaterThan(0));
    expect(failure, greaterThan(cancelled));
    final String branch = js.substring(
      cancelled,
      js.indexOf('} else if (result.ankiConnect) {', cancelled),
    );
    expect(branch, contains('setMineState(false);'));
    expect(branch, isNot(contains('showInlineHint')));
    expect(branch, isNot(contains('duplicateCheck')));
  });

  group('pickScreenOcrCardFrame（真框选页）', () {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    Future<Future<MiningRequestOverrides?>> openPicker(
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          theme: ThemeData(
            extensions: const <ThemeExtension<dynamic>>[
              FushiGlassTheme(FushiGlassMaterial.off),
            ],
          ),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      );
      final Future<MiningRequestOverrides?> picked = pickScreenOcrCardFrame(
        navKey.currentContext!,
        source(),
      );
      // 读图 / 量尺寸走真异步，放出去跑完再推帧。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      return picked;
    }

    testWidgets('主按钮是「制卡」；不动直接制卡 = 一键「+」的自动框', (WidgetTester tester) async {
      final Future<MiningRequestOverrides?> picked = await openPicker(tester);
      expect(
        find.text(t.popup_advanced_mining_crop_page_title),
        findsOneWidget,
      );
      expect(find.text(t.screen_ocr_card_frame_confirm), findsOneWidget);
      expect(find.text(t.popup_advanced_mining_crop_done), findsNothing);

      await tester.tap(find.text(t.screen_ocr_card_frame_confirm));
      await tester.pumpAndSettle();
      final MiningRequestOverrides? result = await picked;
      expect(result, isNotNull);
      final MiningImageCrop crop = result!.crop!;
      expect(crop.pageIndex, kScreenOcrCardCropPageIndex);
      expect(crop.left, closeTo(40 / 1200, 1e-9));
      expect(crop.top, closeTo(40 / 800, 1e-9));
      expect(crop.right, closeTo(760 / 1200, 1e-9));
      expect(crop.bottom, closeTo(360 / 800, 1e-9));
      // 只出卡图三项，不夹带卡组 / 音频等别的覆盖。
      expect(result.deckName, isNull);
      expect(result.hasAudioDelta, isFalse);
    });

    testWidgets('选「整张截图」再制卡 → 整张图（带上发帖人、时间等上下文）', (WidgetTester tester) async {
      final Future<MiningRequestOverrides?> picked = await openPicker(tester);
      await tester.tap(
        find.text(t.popup_advanced_mining_crop_whole_screenshot).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.screen_ocr_card_frame_confirm));
      await tester.pumpAndSettle();
      final MiningImageCrop crop = (await picked)!.crop!;
      expect(crop.left, 0);
      expect(crop.top, 0);
      expect(crop.right, 1);
      expect(crop.bottom, 1);
    });

    testWidgets('点「×」→ null，这张卡不制', (WidgetTester tester) async {
      final Future<MiningRequestOverrides?> picked = await openPicker(tester);
      await tester.tap(find.byTooltip(t.popup_ctx_cancel));
      await tester.pumpAndSettle();
      expect(await picked, isNull);
      expect(find.text(t.popup_advanced_mining_crop_page_title), findsNothing);
    });
  });
}
