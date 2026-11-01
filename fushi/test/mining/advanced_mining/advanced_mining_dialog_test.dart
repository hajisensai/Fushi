import 'dart:async';

import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/mining_sentence_draft.dart';
import 'package:fushi/src/media/range_playback.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_dialog.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_manga_panels.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_sections.dart'
    show formatAdvancedMiningStepSize;
import 'package:fushi/src/mining/advanced_mining/manga_crop_selector.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show VideoMiningImageMode;
import 'package:material_ui/material_ui.dart';

import '../../helpers/glass_unwrap.dart';
import 'advanced_mining_test_host.dart';

/// 「高级制卡」对话框的行为测试：分区按能力渲染、宽 / 窄两种布局、从原「调整上下文」
/// 对话框迁移过来的修复（BUG-2627 / 922 / 3211、取消还原快照、编辑锁）、确认产出
/// 的覆盖项，以及焦点驱动可达。
void main() {
  late FakeAdvancedMiningHost host;
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

  setUp(() => host = FakeAdvancedMiningHost());

  Future<void> open(
    WidgetTester tester,
    AdvancedMiningCapabilities caps, {
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // BUG-2627：失败提示走 FushiToast 的自绘 overlay，要经 navigatorKey 找 overlay。
    FushiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => Center(
              child: TextButton(
                onPressed: () => unawaited(
                  showAdvancedMiningDialog(context: ctx, capabilities: caps),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  String confirmLabel([String deck = '日语::挖矿']) =>
      t.popup_advanced_mining_confirm_to_deck(deck: deck);

  Future<void> confirm(WidgetTester tester, [String? label]) async {
    await tester.tap(find.text(label ?? confirmLabel()));
    await tester.pumpAndSettle();
  }

  Finder chevrons() => find.byIcon(FushiIcons.chevronRight);

  group('分区按能力渲染', () {
    testWidgets('只有卡组：不渲染句子 / 音频 / 图片', (WidgetTester tester) async {
      await open(tester, host.capabilities(deck: host.deck()));
      expect(find.text(t.popup_advanced_mining_title), findsOneWidget);
      expect(find.text(t.popup_advanced_mining_deck_section), findsOneWidget);
      expect(find.text(t.popup_advanced_mining_sentence_section), findsNothing);
      expect(find.text(t.popup_advanced_mining_audio_section), findsNothing);
      expect(find.text(t.popup_advanced_mining_image_section), findsNothing);
      expect(find.text(confirmLabel()), findsOneWidget);
    });

    testWidgets('没有卡组分区：主按钮退回「确认制卡」', (WidgetTester tester) async {
      await open(tester, host.capabilities(sentence: host.sentence()));
      expect(find.text(t.popup_ctx_confirm), findsOneWidget);
      expect(find.text(t.popup_advanced_mining_deck_section), findsNothing);
    });

    testWidgets('卡组列表为空：只显示默认名 + 连 Anki 提示', (WidgetTester tester) async {
      await open(
        tester,
        host.capabilities(deck: host.deck(decks: const <String>[])),
      );
      expect(find.text('日语::挖矿'), findsOneWidget);
      expect(
        find.text(t.popup_advanced_mining_deck_unavailable),
        findsOneWidget,
      );
      expect(find.text(t.popup_advanced_mining_deck_set_default), findsNothing);
    });

    testWidgets('describe 为 null：显示无音频、不给微调', (WidgetTester tester) async {
      host.audioAvailable = false;
      await open(
        tester,
        host.capabilities(sentence: host.sentence(), audio: host.audio()),
      );
      expect(
        find.text(t.popup_advanced_mining_audio_unavailable),
        findsOneWidget,
      );
      expect(find.text('+0.25s'), findsNothing);
    });
  });

  group('宽屏双栏', () {
    testWidgets('句子在左、卡组 / 音频 / 图片在右，无折叠摘要行', (WidgetTester tester) async {
      await open(tester, host.videoPage());
      final double sentenceX = tester
          .getTopLeft(find.text(t.popup_advanced_mining_sentence_section))
          .dx;
      final double deckX = tester
          .getTopLeft(find.text(t.popup_advanced_mining_deck_section))
          .dx;
      expect(deckX, greaterThan(sentenceX + 300));
      expect(chevrons(), findsNothing);
      // 当前句 + 前后文 + 计数（3 句 · 3.0 s）
      expect(find.textContaining('諦め', findRichText: true), findsWidgets);
      expect(
        find.textContaining(t.popup_advanced_mining_sentence_count(count: 3)),
        findsOneWidget,
      );
      expect(find.text(t.popup_advanced_mining_reset), findsOneWidget);
    });

    testWidgets('漫画：左栏是裁切工作区，右栏有卡片预览', (WidgetTester tester) async {
      await open(tester, host.mangaPage());
      expect(find.byType(MangaCropSelector), findsOneWidget);
      expect(find.text(t.popup_advanced_mining_crop_preview), findsOneWidget);
      expect(find.text(t.popup_advanced_mining_crop_panel), findsOneWidget);
      expect(find.text(t.popup_advanced_mining_crop_no_model), findsNothing);
    });

    testWidgets('漫画无模型：显示提示与下载入口，默认文字周围', (WidgetTester tester) async {
      await open(tester, host.mangaPage(modelAvailable: false));
      expect(find.text(t.popup_advanced_mining_crop_no_model), findsOneWidget);
      expect(find.textContaining('9.3 MB'), findsOneWidget);
      await confirm(tester);
      final MiningImageCrop crop = host.confirms.single.crop!;
      expect(crop.left, closeTo(0.55, 1e-9));
      expect(crop.pageIndex, 46);
    });
  });

  group('窄屏', () {
    testWidgets('窄对话框：卡组 / 音频 / 图片折叠成摘要行，点开就地展开', (WidgetTester tester) async {
      await open(tester, host.videoPage(), size: const Size(800, 900));
      expect(chevrons(), findsNWidgets(3));
      expect(find.text('+0.25s'), findsNothing);
      expect(find.text('日语::挖矿'), findsOneWidget, reason: '卡组摘要');
      await tester.tap(find.text(t.popup_advanced_mining_audio_section));
      await tester.pumpAndSettle();
      expect(find.text('+0.25s'), findsNWidgets(2));
    });

    testWidgets('手机宽度走底部面板，主按钮通栏', (WidgetTester tester) async {
      await open(tester, host.videoPage(), size: const Size(390, 844));
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(chevrons(), findsNWidgets(3));
      final double button = tester.getSize(find.text(confirmLabel())).width;
      expect(button, greaterThan(0));
      await tester.tap(find.text(t.popup_ctx_cancel));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(host.closedCalls, 1);
    });

    testWidgets('手机漫画：图片行进入全屏框选，「完成」保留、× 放弃', (WidgetTester tester) async {
      await open(tester, host.mangaPage(), size: const Size(390, 844));
      expect(find.byType(MangaCropSelector), findsNothing);
      await tester.tap(find.text(t.popup_advanced_mining_image_section));
      await tester.pumpAndSettle();
      expect(find.byType(MangaCropSelector), findsOneWidget);
      expect(
        find.text(t.popup_advanced_mining_crop_page_title),
        findsOneWidget,
      );
      // BUG-3410：「完成」在顶栏动作胶囊里水平居中，不能被页面自带的尾部
      // Padding 挤到左边。
      final Finder done = find.text(t.popup_advanced_mining_crop_done);
      final Rect doneButton = tester.getRect(
        find.ancestor(of: done, matching: find.byType(FushiFilledButton)),
      );
      final Rect capsule = tester.getRect(
        find.ancestor(of: done, matching: find.byType(FushiPageChromeCapsule)),
      );
      expect(
        doneButton.left - capsule.left,
        moreOrLessEquals(capsule.right - doneButton.right, epsilon: 0.5),
      );
      await tester.tap(find.text(t.popup_advanced_mining_crop_whole_page).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.popup_advanced_mining_crop_done));
      await tester.pumpAndSettle();
      expect(find.byType(MangaCropSelector), findsNothing);
      expect(
        find.textContaining(t.popup_advanced_mining_crop_whole_page),
        findsOneWidget,
      );
      await confirm(tester);
      expect(host.confirms.single.crop!.isWholePage, isTrue);
    });

    for (final AppLocale locale in <AppLocale>[AppLocale.en, AppLocale.zhCn]) {
      testWidgets('360 宽全屏框选：取景分段文字完整、不溢出（${locale.name}）', (
        WidgetTester tester,
      ) async {
        LocaleSettings.setLocale(locale);
        addTearDown(() => LocaleSettings.setLocale(AppLocale.en));
        await open(
          tester,
          host.mangaPage(modelAvailable: false),
          size: const Size(360, 780),
        );
        // 图片摘要行在句子区下面，矮屏要先滚到可见再点。
        await tester.ensureVisible(
          find.text(t.popup_advanced_mining_image_section),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(t.popup_advanced_mining_image_section));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '不许有 RenderFlex 溢出');
        final Finder bar = find.byType(MangaCropChoiceSegments);
        expect(bar, findsOneWidget);
        for (final String label in <String>[
          t.popup_advanced_mining_crop_whole_page,
          t.popup_advanced_mining_crop_text_area,
          t.popup_advanced_mining_crop_custom,
          t.popup_advanced_mining_image_none,
        ]) {
          final Finder text = find.descendant(
            of: bar,
            matching: find.text(label),
          );
          expect(text, findsOneWidget, reason: '「$label」整段文字原样渲染');
          final RenderParagraph p = tester.renderObject<RenderParagraph>(text);
          expect(p.didExceedMaxLines, isFalse, reason: '「$label」不得被截断');
          // FittedBox 缩小后，文字画出来的范围必须落在自己那一段里。
          final Rect drawn = tester.getRect(text);
          final Rect seg = tester.getRect(
            find
                .ancestor(of: text, matching: find.byType(AnimatedContainer))
                .first,
          );
          expect(drawn.left, greaterThanOrEqualTo(seg.left - 0.5));
          expect(drawn.right, lessThanOrEqualTo(seg.right + 0.5));
        }
        expect(
          find.descendant(of: bar, matching: find.textContaining('…')),
          findsNothing,
        );
      });
    }

    testWidgets('BUG-922：矮窗里句子卡仍有真实高度（整块滚动，不塌）', (WidgetTester tester) async {
      host.prevCount = 3;
      host.nextCount = 3;
      await open(tester, host.videoPage(), size: const Size(700, 360));
      final Finder current = find.textContaining('諦め', findRichText: true);
      expect(current, findsWidgets);
      expect(tester.getSize(current.first).height, greaterThan(10));
      // 主按钮固定在底部、始终可点。
      expect(tester.getBottomLeft(find.text(confirmLabel())).dy, lessThan(360));
    });
  });

  group('确认产出覆盖项', () {
    testWidgets('未改动：覆盖项为空', (WidgetTester tester) async {
      await open(tester, host.videoPage());
      await confirm(tester);
      expect(host.confirms.single.isEmpty, isTrue);
      expect(host.closedCalls, 1);
    });

    testWidgets('不要音频：视频片段置灰 + 提示，确认带 omitAudio', (WidgetTester tester) async {
      await open(tester, host.videoPage());
      // 英文下音频与图片的「不要」同为 None；音频分区在上。
      await tester.tap(find.text(t.popup_advanced_mining_audio_none).first);
      await tester.pumpAndSettle();
      expect(
        find.text(t.popup_advanced_mining_image_clip_needs_audio),
        findsOneWidget,
      );
      final ChoiceChip clip = tester.widget<ChoiceChip>(
        glassUnwrap<ChoiceChip>(
          find.ancestor(
            of: find.text(t.popup_advanced_mining_image_mode_clip),
            matching: find.byWidgetPredicate((Widget w) => w is ChoiceChip),
          ),
        ),
      );
      expect(clip.onSelected, isNull);
      await confirm(tester);
      expect(host.confirms.single.omitAudio, isTrue);
    });

    testWidgets('音频终点 +0.25s：重新 describe，偏移进覆盖项', (WidgetTester tester) async {
      await open(tester, host.videoPage());
      await tester.ensureVisible(find.text('+0.25s').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('+0.25s').last);
      await tester.pumpAndSettle();
      expect(host.describeCalls.last, <int>[0, 250]);
      await confirm(tester);
      expect(host.confirms.single.audioEndDeltaMs, 250);
    });

    testWidgets('换步长 0.1s（反馈 3_VB7kAeHj）：按钮按新步长挪，偏移进覆盖项', (
      WidgetTester tester,
    ) async {
      await open(tester, host.videoPage());
      await tester.ensureVisible(find.text('0.1s').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('0.1s').last);
      await tester.pumpAndSettle();
      expect(find.text('+0.25s'), findsNothing);
      await tester.ensureVisible(find.text('+0.1s').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('+0.1s').last);
      await tester.pumpAndSettle();
      expect(host.describeCalls.last, <int>[0, 100]);
      await confirm(tester);
      expect(host.confirms.single.audioEndDeltaMs, 100);
    });

    test('步长文案去尾零', () {
      expect(formatAdvancedMiningStepSize(50), '0.05s');
      expect(formatAdvancedMiningStepSize(100), '0.1s');
      expect(formatAdvancedMiningStepSize(250), '0.25s');
      expect(formatAdvancedMiningStepSize(1000), '1s');
      expect(normalizeAdvancedMiningAudioNudgeStepMs(123), 250);
      expect(normalizeAdvancedMiningAudioNudgeStepMs(null), 250);
    });

    testWidgets('换卡组 + 设为默认：先持久化默认再制卡', (WidgetTester tester) async {
      await open(tester, host.videoPage());
      await tester.tap(find.text('日语::挖矿').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('日语::听力').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.popup_advanced_mining_deck_set_default));
      await tester.pumpAndSettle();
      await confirm(tester, confirmLabel('日语::听力'));
      expect(host.setDefaultDeckCalls, <String>['日语::听力']);
      expect(host.confirms.single.deckName, '日语::听力');
    });

    testWidgets('「恢复默认」：所有选择与句子快照归位', (WidgetTester tester) async {
      await open(tester, host.videoPage());
      await tester.tap(find.text(t.popup_ctx_prev_plus));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.text(t.popup_advanced_mining_image_none).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.popup_advanced_mining_image_none).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.popup_advanced_mining_reset));
      await tester.pumpAndSettle();
      expect(host.setContextCalls.last, <int>[1, 1]);
      await confirm(tester);
      expect(host.confirms.single.isEmpty, isTrue);
    });
  });

  group('迁移自「调整上下文」的行为', () {
    testWidgets('BUG-2627：往返未落地前对话框不关、外层锁住', (WidgetTester tester) async {
      host.confirmGate = Completer<bool>();
      await open(tester, host.videoPage());
      await tester.tap(find.text(confirmLabel()));
      await tester.pump();
      expect(find.text(t.popup_advanced_mining_title), findsOneWidget);
      // Esc 在往返途中不放行。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text(t.popup_advanced_mining_title), findsOneWidget);
      host.confirmGate!.complete(true);
      await tester.pumpAndSettle();
      expect(find.text(t.popup_advanced_mining_title), findsNothing);
      expect(find.text(t.popup_ctx_confirm_failed), findsNothing);
    });

    testWidgets('BUG-2627：没点到制卡按钮 → 关窗并如实提示', (WidgetTester tester) async {
      host.confirmResult = false;
      await open(tester, host.videoPage());
      await confirm(tester);
      expect(find.text(t.popup_advanced_mining_title), findsNothing);
      expect(find.text(t.popup_ctx_confirm_failed), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('取消：上下文还原到打开时的快照，试听停止', (WidgetTester tester) async {
      await open(tester, host.videoPage());
      await tester.tap(find.text(t.popup_ctx_next_plus));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(t.popup_ctx_preview_audio).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.popup_ctx_cancel));
      await tester.pumpAndSettle();
      expect(host.setContextCalls.last, <int>[1, 1]);
      expect(host.stopCalls, 1);
      expect(host.confirms, isEmpty);
    });

    testWidgets('BUG-3814：试听播完按钮自动回到「试听」，再点一次就重新播', (
      WidgetTester tester,
    ) async {
      await open(tester, host.videoPage());
      await tester.tap(find.byTooltip(t.popup_ctx_preview_audio).first);
      await tester.pumpAndSettle();
      expect(find.byTooltip(t.popup_ctx_preview_stop), findsWidgets);

      host.playbacks.single.finish(RangePlaybackEnd.reachedEnd);
      await tester.pumpAndSettle();
      expect(find.byTooltip(t.popup_ctx_preview_stop), findsNothing);

      await tester.tap(find.byTooltip(t.popup_ctx_preview_audio).first);
      await tester.pumpAndSettle();
      expect(host.previewCalls, hasLength(2), reason: '一次点击就重新试听');
      expect(host.stopCalls, 0);
      expect(find.byTooltip(t.popup_ctx_preview_stop), findsWidgets);
    });

    testWidgets('× 最外侧句 = 少要一句；中间句 = 删除线 + 恢复', (WidgetTester tester) async {
      host.prevCount = 2;
      await open(tester, host.videoPage());
      await tester.tap(find.byTooltip(t.popup_ctx_sentence_remove).at(1));
      await tester.pumpAndSettle();
      expect(host.removeCalls.single, <Object>[
        SentenceContextSlot.prev,
        1,
        true,
      ]);
      expect(find.byTooltip(t.popup_ctx_sentence_restore), findsOneWidget);
      await tester.tap(find.byTooltip(t.popup_ctx_sentence_remove).first);
      await tester.pumpAndSettle();
      expect(host.setContextCalls.last, <int>[1, 1]);
    });

    testWidgets('编辑态锁住外层：主按钮禁用、快捷键不拦截', (WidgetTester tester) async {
      await open(tester, host.videoPage());
      await tester.tap(find.byTooltip(t.popup_ctx_edit_start).first);
      await tester.pumpAndSettle();
      final FilledButton primary = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text(confirmLabel()),
          matching: find.byWidgetPredicate((Widget w) => w is FilledButton),
        ),
      );
      expect(primary.onPressed, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await tester.pumpAndSettle();
      expect(host.setContextCalls, isEmpty);
      // 卡组下拉在 Android 上也是一个输入框，按句子原文认编辑器。
      await tester.enterText(
        find.byWidgetPredicate(
          (Widget w) => w is EditableText && w.controller.text == 'まえ0。',
        ),
        '直した。',
      );
      await tester.tap(find.text(t.popup_ctx_edit_confirm));
      await tester.pumpAndSettle();
      expect(host.editCalls.single.last, '直した。');
      expect(find.text('直した。'), findsOneWidget);
    });

    testWidgets('快捷键：[ 加前文、Shift+] 减后文', (WidgetTester tester) async {
      await open(tester, host.videoPage());
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await tester.pumpAndSettle();
      expect(host.setContextCalls.last, <int>[2, 1]);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(host.setContextCalls.last, <int>[2, 0]);
    });
  });

  group('焦点驱动', () {
    testWidgets('打开即聚焦主按钮，Enter 确认', (WidgetTester tester) async {
      await open(tester, host.videoPage());
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(host.confirms, hasLength(1));
    });

    testWidgets('Tab 遍历能回到主按钮（焦点在对话框内闭环）', (WidgetTester tester) async {
      await open(
        tester,
        host.capabilities(
          deck: host.deck(),
          audio: host.audio(),
          sentence: host.sentence(),
        ),
      );
      // 先离开主按钮，再一路 Tab 直到焦点回到它身上。
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      bool reached = false;
      for (int i = 0; i < 60 && !reached; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final BuildContext? focused =
            FocusManager.instance.primaryFocus?.context;
        reached =
            focused != null &&
            find
                .descendant(
                  of: find.byWidget(focused.widget),
                  matching: find.text(confirmLabel()),
                )
                .evaluate()
                .isNotEmpty;
      }
      expect(reached, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(host.confirms, hasLength(1));
    });
  });

  test('视频方式标签齐全', () {
    for (final VideoMiningImageMode m in VideoMiningImageMode.values) {
      expect(m.wireName, isNotEmpty);
    }
  });
}
