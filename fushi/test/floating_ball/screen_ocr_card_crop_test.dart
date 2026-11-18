import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/screen_ocr_card_image.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_controller.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:image/image.dart' as img;

import '../mining/advanced_mining/advanced_mining_test_host.dart';

/// 反馈 mOe5HjBtuG：截屏识字制卡时像漫画那样在「高级制卡」里调整卡图——截图交给漫画
/// 同款裁切分区，预选框 = 一键「+」的自动裁切框，确认后的框选 / 打码 / 不要图回到
/// 制卡路径出图。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List whitePng(int width, int height) {
    final img.Image page = img.Image(width: width, height: height);
    img.fill(page, color: img.ColorRgb8(255, 255, 255));
    return img.encodePng(page);
  }

  // 1200×800 截图；文本块 (100,100)-(700,300)，行粗 40 → 留白 60 → 自动框
  // (40,40)-(760,360)。
  ScreenOcrCardImage source() => ScreenOcrCardImage(
    bytes: whitePng(1200, 800),
    textBlock: const Rect.fromLTRB(100, 100, 700, 300),
    line: const Rect.fromLTRB(100, 100, 700, 140),
  );

  group('screenOcrCropSuggestions（预选 = 一键「+」的自动框，归一化）', () {
    test('文字周围 = 自动裁切框；这句话的位置 = 文本块；没有分镜', () {
      final MangaCropSuggestions s = screenOcrCropSuggestions(
        source(),
        const Size(1200, 800),
      );
      expect(s.pageIndex, kScreenOcrCardCropPageIndex);
      expect(s.pageSize, const Size(1200, 800));
      expect(s.panels, isEmpty);
      expect(s.containingPanel, isNull);
      final Rect area = s.textAreaRect!;
      expect(area.left, closeTo(40 / 1200, 1e-9));
      expect(area.top, closeTo(40 / 800, 1e-9));
      expect(area.right, closeTo(760 / 1200, 1e-9));
      expect(area.bottom, closeTo(360 / 800, 1e-9));
      final Rect text = s.textRect!;
      expect(text.left, closeTo(100 / 1200, 1e-9));
      expect(text.bottom, closeTo(300 / 800, 1e-9));
    });
  });

  group('resolveScreenOcrCardImagePlan（对话框覆盖项 → 出图方案）', () {
    const MiningMosaicRegion mosaic = MiningMosaicRegion(
      left: 0.1,
      top: 0.1,
      right: 0.2,
      bottom: 0.2,
    );

    test('一键「+」（无覆盖项）→ 自动裁到文本块', () {
      expect(
        resolveScreenOcrCardImagePlan(null).kind,
        ScreenOcrCardImageKind.auto,
      );
    });

    test('选了「不要」→ 不要卡图', () {
      expect(
        resolveScreenOcrCardImagePlan(
          const MiningRequestOverrides(omitImage: true),
        ).kind,
        ScreenOcrCardImageKind.omit,
      );
    });

    test('框选（截图页号）→ 按框裁，带打码', () {
      final ScreenOcrCardImagePlan plan = resolveScreenOcrCardImagePlan(
        const MiningRequestOverrides(
          crop: MiningImageCrop(
            pageIndex: kScreenOcrCardCropPageIndex,
            left: 0,
            top: 0.25,
            right: 0.5,
            bottom: 1,
          ),
          mosaic: <MiningMosaicRegion>[mosaic],
        ),
      );
      expect(plan.kind, ScreenOcrCardImageKind.crop);
      expect(plan.crop, const Rect.fromLTRB(0, 0.25, 0.5, 1));
      expect(plan.mosaic, hasLength(1));
    });

    test('页号对不上：没打码退回自动；打了码就不要图（不把要遮的东西送进卡）', () {
      const MiningImageCrop foreign = MiningImageCrop(
        pageIndex: 7,
        left: 0,
        top: 0,
        right: 0.5,
        bottom: 0.5,
      );
      expect(
        resolveScreenOcrCardImagePlan(
          const MiningRequestOverrides(crop: foreign),
        ).kind,
        ScreenOcrCardImageKind.auto,
      );
      expect(
        resolveScreenOcrCardImagePlan(
          const MiningRequestOverrides(
            crop: foreign,
            mosaic: <MiningMosaicRegion>[mosaic],
          ),
        ).kind,
        ScreenOcrCardImageKind.omit,
      );
      expect(
        resolveScreenOcrCardImagePlan(
          const MiningRequestOverrides(mosaic: <MiningMosaicRegion>[mosaic]),
        ).kind,
        ScreenOcrCardImageKind.omit,
      );
    });
  });

  group('writeScreenOcrCardImage(crop:)：按对话框里框的裁', () {
    test('左下半张 → 600×400 比例', () async {
      final ({String path, Directory dir})? out = await writeScreenOcrCardImage(
        source(),
        imageTier: 3,
        crop: const Rect.fromLTRB(0, 0.5, 0.5, 1),
      );
      expect(out, isNotNull);
      addTearDown(() => deleteScreenOcrCardDir(out!.dir));
      final img.Image card = img.decodeImage(
        await File(out!.path).readAsBytes(),
      )!;
      expect(card.width / card.height, closeTo(600 / 400, 0.02));
    });
  });

  group('高级制卡裁切分区（截图模式）', () {
    test('分区：截图来源、无分镜；默认文字周围，确认带截图页号的自动框', () async {
      final AdvancedMiningMangaImageSection section =
          screenOcrAdvancedMiningImageSection(source());
      expect(section.source, AdvancedMiningCropSource.screenshot);
      expect(section.hasPanels, isFalse);
      expect(section.panelModelAvailable, isFalse);
      expect(section.downloadPanelModel, isNull);

      final FakeAdvancedMiningHost host = FakeAdvancedMiningHost();
      final AdvancedMiningController c = AdvancedMiningController(
        host.capabilities(deck: host.deck(), manga: section),
      );
      addTearDown(c.dispose);
      await c.load();
      expect(c.cropsScreenshot, isTrue);
      expect(c.pageBytes, isNotNull);
      expect(c.isCropChoiceAvailable(MangaCropChoice.panel), isFalse);
      expect(c.cropChoice, MangaCropChoice.textArea);

      // 不动直接确认 = 一键「+」同一张图：框就是自动裁切框。
      final MiningImageCrop crop = c.buildOverrides().crop!;
      expect(crop.pageIndex, kScreenOcrCardCropPageIndex);
      expect(crop.left, closeTo(40 / 1200, 1e-9));
      expect(crop.right, closeTo(760 / 1200, 1e-9));

      // 自定义框 → 制卡路径按这个框裁。
      c.setCropRect(const Rect.fromLTRB(0.5, 0.5, 1, 1));
      final ScreenOcrCardImagePlan plan = resolveScreenOcrCardImagePlan(
        c.buildOverrides(),
      );
      expect(plan.kind, ScreenOcrCardImageKind.crop);
      expect(plan.crop, const Rect.fromLTRB(0.5, 0.5, 1, 1));

      // 「不要」→ 不出图。
      c.selectCropChoice(MangaCropChoice.none);
      expect(
        resolveScreenOcrCardImagePlan(c.buildOverrides()).kind,
        ScreenOcrCardImageKind.omit,
      );
    });
  });
}
