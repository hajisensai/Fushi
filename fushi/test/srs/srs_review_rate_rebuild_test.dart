// 评分后下一张卡掉帧（Windows 实测见 integration_test/srs_rate_next_frame_itest.dart）的两条根因：
//
// 1. 复习页每评一张卡都发 srsRevisionProvider：压在下面的牌组列表随之整库重算计数、整页重建
//    两三次（每次评分约 7000 个 element），正撞在下一张卡上屏的那几帧。现在复习页的写操作只发
//    srsLocalWriteProvider（互联推送用），列表在复习页返回时由入口统一刷新。
// 2. 复习页与卡面无关的 setState（忙碌态开 / 关、计数与间隔预览补齐）每次都新建卡面 widget，
//    卡面整棵重建三四遍。现在卡面输入没变就复用同一个 widget 实例，换一张卡卡面只建一次。
//
// 走真实路径：内存库 + 确定性假排程内核 → SrsReviewPage，键盘翻面 / 评分。

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

/// 卡面 build 记录：（卡 id, 是否答案面）。
final List<(String, bool)> _faceBuilds = <(String, bool)>[];

class _CountingFace extends StatelessWidget {
  const _CountingFace({required this.face});

  final SrsCardFace face;

  @override
  Widget build(BuildContext context) {
    _faceBuilds.add((face.cardId, face.showingAnswer));
    return SrsPlainCardFace(face: face);
  }
}

Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    _faceBuilds.clear();
  });

  testWidgets('评分换卡：不发列表刷新信号，卡面对下一张只建一次', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
      () => openSrsTestStore(),
    ))!;
    addTearDown(() => tester.runAsync(db.close));
    for (int i = 0; i < 3; i++) {
      await tester.runAsync(
        () => store.createNote(
          noteTypeId: store.lapisNoteTypeId,
          createdAt: 1700000000000 + i,
          fieldsById: <String, String>{
            srsLapisFieldId(kSrsTestProfile, 'Expression'): '単語$i',
            srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): '意味$i',
          },
        ),
      );
    }
    final AppModel app = AppModel(testPlatformServices());
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => app),
        srsStoreProvider.overrideWith((Ref ref) async => store),
        srsMediaStoreProvider.overrideWith(
          (Ref ref) async => null as SrsMediaStore?,
        ),
        srsCardFaceBuilderProvider.overrideWithValue(
          (BuildContext context, SrsCardFace face) => _CountingFace(face: face),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            theme: buildFushiThemeData(
              scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
              textTheme: Typography.material2021().black,
              designSystem: FushiDesignSystem.material,
              glass: FushiGlassMaterial.off,
              glassDesign: false,
            ),
            builder: (BuildContext context, Widget? child) =>
                FushiGlassScope(child: child!),
            home: SrsReviewPage(
              deckId: store.defaultDeckId,
              deckName: 'Default',
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(_faceBuilds, isNotEmpty);
    final String first = _faceBuilds.last.$1;
    expect(first, isNotEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _settle(tester);
    expect(_faceBuilds.last, (first, true));

    final int revisionBefore = container.read(srsRevisionProvider);
    final int localBefore = container.read(srsLocalWriteProvider);
    _faceBuilds.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await _settle(tester, rounds: 20);

    expect(_faceBuilds, isNotEmpty, reason: '评分后应换到下一张');
    final String next = _faceBuilds.last.$1;
    expect(next, isNot(first));
    expect(
      _faceBuilds,
      <(String, bool)>[(next, false)],
      reason:
          '换一张卡卡面只该建一次（下一张的问题面）；忙碌态开关、计数 / 间隔预览补齐'
          '不应让卡面整棵重建',
    );
    expect(
      container.read(srsRevisionProvider),
      revisionBefore,
      reason: '评分不叫醒被复习页盖住的牌组列表 / 首页（入口在返回时统一刷新）',
    );
    expect(
      container.read(srsLocalWriteProvider),
      greaterThan(localBefore),
      reason: '评分仍要通知互联推送',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
