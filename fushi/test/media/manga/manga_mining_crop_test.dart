import 'dart:io';
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_mining_crop.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/media/manga/panel_detection.dart';

import '../../helpers/source_guard.dart';

void main() {
  group('mangaContainingPanel', () {
    const Rect left = Rect.fromLTRB(0, 0, 0.5, 0.5);
    const Rect right = Rect.fromLTRB(0.5, 0, 1, 0.5);
    const Rect bottom = Rect.fromLTRB(0, 0.5, 1, 1);

    test('取包含文本中心的分镜', () {
      expect(
        mangaContainingPanel(<Rect>[
          left,
          right,
          bottom,
        ], const Rect.fromLTRB(0.6, 0.1, 0.7, 0.3)),
        right,
      );
    });

    test('多个分镜都包含中心时取最贴身（面积最小）的那格', () {
      const Rect outer = Rect.fromLTRB(0, 0, 1, 1);
      const Rect inner = Rect.fromLTRB(0.4, 0.4, 0.8, 0.8);
      expect(
        mangaContainingPanel(<Rect>[
          outer,
          inner,
        ], const Rect.fromLTRB(0.5, 0.5, 0.6, 0.6)),
        inner,
      );
    });

    test('中心落在分镜缝里时取 IoU 最大者；都不沾边返回 null', () {
      const Rect a = Rect.fromLTRB(0, 0, 0.45, 1);
      const Rect b = Rect.fromLTRB(0.55, 0, 1, 1);
      // 中心 x=0.49 在缝里，左边重叠更多。
      expect(
        mangaContainingPanel(<Rect>[
          a,
          b,
        ], const Rect.fromLTRB(0.40, 0.2, 0.58, 0.3)),
        a,
      );
      expect(
        mangaContainingPanel(<Rect>[
          const Rect.fromLTRB(0, 0, 0.1, 0.1),
        ], const Rect.fromLTRB(0.5, 0.5, 0.6, 0.6)),
        isNull,
      );
      expect(
        mangaContainingPanel(const <Rect>[], const Rect.fromLTRB(0, 0, 1, 1)),
        isNull,
      );
    });

    test('PanelRect 原样换成同一坐标系的 Rect', () {
      expect(
        mangaPanelToRect(
          const PanelRect(left: 0.1, top: 0.2, right: 0.3, bottom: 0.4),
        ),
        const Rect.fromLTRB(0.1, 0.2, 0.3, 0.4),
      );
    });
  });

  group('expandMangaTextRect', () {
    test('按中心把宽高各放大 3.5 倍', () {
      final Rect r = expandMangaTextRect(
        const Rect.fromLTRB(0.45, 0.45, 0.55, 0.55),
      );
      expect(r.width, closeTo(0.35, 1e-9));
      expect(r.height, closeTo(0.35, 1e-9));
      expect(r.center.dx, closeTo(0.5, 1e-9));
      expect(r.center.dy, closeTo(0.5, 1e-9));
    });

    test('贴边时整体挪进页面，保住面积', () {
      final Rect r = expandMangaTextRect(
        const Rect.fromLTRB(0.0, 0.9, 0.1, 1.0),
      );
      expect(r.width, closeTo(0.35, 1e-9));
      expect(r.left, 0);
      expect(r.bottom, closeTo(1, 1e-9));
      expect(r.top, closeTo(0.65, 1e-9));
    });

    test('放大后超过整页的一维直接取整页', () {
      final Rect r = expandMangaTextRect(
        const Rect.fromLTRB(0.2, 0.4, 0.8, 0.5),
      );
      expect(r.left, 0);
      expect(r.right, 1);
      expect(r.height, closeTo(0.35, 1e-9));
    });
  });

  group('computeMangaCropSuggestions', () {
    const Size size = Size(1200, 1800);
    const Rect text = Rect.fromLTRB(0.6, 0.1, 0.7, 0.3);
    const List<Rect> panels = <Rect>[
      Rect.fromLTRB(0.5, 0, 1, 0.5),
      Rect.fromLTRB(0, 0, 0.5, 0.5),
    ];

    test('有分镜 + 文本位置：分镜、所在分镜、外扩框齐全', () {
      final MangaCropSuggestions s = computeMangaCropSuggestions(
        pageIndex: 3,
        pageSize: size,
        panels: panels,
        textRect: text,
      );
      expect(s.pageIndex, 3);
      expect(s.pageSize, size);
      expect(s.panels, panels);
      expect(s.containingPanel, panels[0]);
      expect(s.textRect, text);
      expect(s.textAreaRect, isNotNull);
    });

    test('没有分镜（模型不可用 / 条漫）：只有外扩框', () {
      final MangaCropSuggestions s = computeMangaCropSuggestions(
        pageIndex: 0,
        pageSize: size,
        textRect: text,
      );
      expect(s.panels, isEmpty);
      expect(s.containingPanel, isNull);
      expect(s.textAreaRect, isNotNull);
    });

    test('拿不到 OCR 位置：整页（什么框都不给）', () {
      final MangaCropSuggestions s = computeMangaCropSuggestions(
        pageIndex: 0,
        pageSize: size,
        panels: panels,
      );
      expect(s.panels, panels);
      expect(s.containingPanel, isNull);
      expect(s.textRect, isNull);
      expect(s.textAreaRect, isNull);
    });
  });

  group('resolveMangaCardImagePlan', () {
    MangaCardImagePlan plan({
      MiningRequestOverrides? overrides,
      int? page = 2,
      bool setting = false,
      bool webtoon = false,
    }) => resolveMangaCardImagePlan(
      overrides: overrides,
      miningPageIndex: page,
      cropToPanelByDefault: setting,
      webtoon: webtoon,
    );

    const MiningImageCrop crop = MiningImageCrop(
      pageIndex: 2,
      left: 0.1,
      top: 0.2,
      right: 0.5,
      bottom: 0.6,
    );

    test('omitImage → 不要卡图（压过 crop 与默认设置）', () {
      expect(
        plan(
          overrides: const MiningRequestOverrides(omitImage: true, crop: crop),
          setting: true,
        ).kind,
        MangaCardImageKind.omit,
      );
    });

    test('crop 与本次制卡页一致 → 按 crop 裁', () {
      final MangaCardImagePlan p = plan(
        overrides: const MiningRequestOverrides(crop: crop),
      );
      expect(p.kind, MangaCardImageKind.crop);
      expect(p.crop, const Rect.fromLTRB(0.1, 0.2, 0.5, 0.6));
    });

    test('crop 页码对不上 → 整页并留诊断，绝不裁错页', () {
      final MangaCardImagePlan p = plan(
        overrides: const MiningRequestOverrides(crop: crop),
        page: 3,
      );
      expect(p.kind, MangaCardImageKind.wholePage);
      expect(p.diagnostic, isNotNull);
      expect(
        plan(
          overrides: const MiningRequestOverrides(crop: crop),
          page: null,
        ).kind,
        MangaCardImageKind.wholePage,
      );
    });

    test('isWholePage = 用户明确不裁，压过「默认裁到分镜」', () {
      const MiningImageCrop whole = MiningImageCrop(
        pageIndex: 2,
        left: 0,
        top: 0,
        right: 1,
        bottom: 1,
      );
      final MangaCardImagePlan p = plan(
        overrides: const MiningRequestOverrides(crop: whole),
        setting: true,
      );
      expect(p.kind, MangaCardImageKind.wholePage);
      expect(p.diagnostic, isNull);
    });

    test('没有 crop：设置开 + 非条漫 + 知道页 → 裁到所在分镜', () {
      expect(plan(setting: true).kind, MangaCardImageKind.autoPanel);
      expect(
        plan(
          overrides: const MiningRequestOverrides(deckName: 'x'),
          setting: true,
        ).kind,
        MangaCardImageKind.autoPanel,
      );
    });

    group('打码', () {
      const List<MiningMosaicRegion> mosaic = <MiningMosaicRegion>[
        MiningMosaicRegion(left: 0.2, top: 0.3, right: 0.4, bottom: 0.5),
      ];

      test('与裁切同页 → 裁切计划带上打码（坐标原样，相对整页）', () {
        final MangaCardImagePlan p = plan(
          overrides: const MiningRequestOverrides(crop: crop, mosaic: mosaic),
        );
        expect(p.kind, MangaCardImageKind.crop);
        expect(p.crop, const Rect.fromLTRB(0.1, 0.2, 0.5, 0.6));
        expect(p.mosaic, mosaic);
      });

      test('整页 + 打码 → 走裁切通道裁 0..1（才能把码打上）', () {
        const MiningImageCrop whole = MiningImageCrop(
          pageIndex: 2,
          left: 0,
          top: 0,
          right: 1,
          bottom: 1,
        );
        final MangaCardImagePlan p = plan(
          overrides: const MiningRequestOverrides(crop: whole, mosaic: mosaic),
        );
        expect(p.kind, MangaCardImageKind.crop);
        expect(p.crop, const Rect.fromLTRB(0, 0, 1, 1));
        expect(p.mosaic, mosaic);
      });

      test('页码对不上 → 不要卡图（绝不退回没打码的整页）', () {
        final MangaCardImagePlan p = plan(
          overrides: const MiningRequestOverrides(crop: crop, mosaic: mosaic),
          page: 3,
        );
        expect(p.kind, MangaCardImageKind.omit);
        expect(p.diagnostic, isNotNull);
      });

      test('有打码却没有取景页（不该出现）→ 不要卡图', () {
        final MangaCardImagePlan p = plan(
          overrides: const MiningRequestOverrides(mosaic: mosaic),
          setting: true,
        );
        expect(p.kind, MangaCardImageKind.omit);
      });
    });

    test('没有 crop：设置关 / 条漫 / 不知道页 → 整页（行为不变）', () {
      expect(plan().kind, MangaCardImageKind.wholePage);
      expect(
        plan(setting: true, webtoon: true).kind,
        MangaCardImageKind.wholePage,
      );
      expect(
        plan(setting: true, page: null).kind,
        MangaCardImageKind.wholePage,
      );
    });
  });

  group('漫画页制卡接线（源码守卫）', () {
    // 注释掩掉再折叠空白（注释里会写「await」之类的字眼），走共享词法掩码。
    final String flat = compactCode(
      File(
        'lib/src/media/manga/reader/manga_fushi_page.dart',
      ).readAsStringSync(),
    );

    String onMineBody() {
      final int start = flat.indexOf(
        'Future<MinePopupResult>onMineFromPopup(Map<String,String>fields)async{',
      );
      expect(start, isNonNegative);
      return flat.substring(
        start,
        flat.indexOf('Future<void>_recordMinedCount'),
      );
    }

    test('覆盖项与制卡页在第一个 await 之前同步读出', () {
      final String body = onMineBody();
      final int read = body.indexOf('MiningRequestOverrides.readFrom(fields,)');
      final int plan = body.indexOf('resolveMangaCardImagePlan(');
      final int firstAwait = body.indexOf('await');
      expect(read, isNonNegative);
      expect(plan, isNonNegative);
      expect(read, lessThan(firstAwait));
      expect(plan, lessThan(firstAwait));
      expect(
        body.contains('cropToPanelByDefault:appModel.mangaMiningCropToPanel'),
        isTrue,
      );
    });

    test('四种分支都接上：不要图 / 用户框 / 自动分镜 / 整页', () {
      final String body = onMineBody();
      expect(
        body.contains('imagePlan.kind!=MangaCardImageKind.omit'),
        isTrue,
        reason: 'omitImage 时不能带卡图',
      );
      expect(body.contains('MangaCardImageKind.crop=>imagePlan.crop'), isTrue);
      expect(
        body.contains('MangaCardImageKind.autoPanel=>await_autoPanelCropRect('),
        isTrue,
      );
      expect(
        body.contains(
          'MangaCardImageKind.wholePage||MangaCardImageKind.omit=>null',
        ),
        isTrue,
      );
      // 裁不出来时保留整页原图：先算整页 coverPath，裁成功才覆盖。
      expect(
        body.indexOf('coverPath=awaitensureMangaCoverPng(pageImage);'),
        lessThan(body.indexOf('coverPath=cropped.path;')),
      );
      // 打了码的裁图失败：不要卡图，不退回整页原图。
      expect(
        body.contains('}elseif(imagePlan.mosaic.isNotEmpty){coverPath=null;'),
        isTrue,
      );
      expect(body.contains('mosaic:imagePlan.mosaic,'), isTrue);
      // 临时裁图在制卡结束后清理。
      expect(body.contains('_deleteTempDir(dir)'), isTrue);
    });

    test('裁切走引擎的后台 isolate，从原图字节出发', () {
      expect(flat.contains('awaitcropMangaPageAsync('), isTrue);
      expect(flat.contains('File(pageImage).readAsBytes()'), isTrue);
      expect(
        flat.contains('maxLongEdge:compression.screenshotMaxLongEdge'),
        isTrue,
        reason: '输出按「制卡图片质量」档缩放',
      );
    });

    test('漫画页覆写高级制卡分区，只提供图片分区', () {
      final int start = flat.indexOf(
        'Future<AdvancedMiningSections>buildAdvancedMiningSections(',
      );
      expect(start, isNonNegative);
      final String body = flat.substring(
        start,
        flat.indexOf('Future<Uint8List?>_loadMiningPageBytes('),
      );
      expect(
        body.contains('mangaImage:AdvancedMiningMangaImageSection('),
        isTrue,
      );
      expect(body.contains('sentence:'), isFalse);
      expect(body.contains('audio:'), isFalse);
      expect(body.contains('videoImage:'), isFalse);
      expect(body.contains('session.page(pageIndex)'), isFalse);
      expect(flat.contains('(awaitsession.page(pageIndex)).bytes'), isTrue);
    });
  });
}
