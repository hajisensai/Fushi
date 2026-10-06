// HBK040 回归（Codex 第 6 轮复现迁入）：同一 spine 内按锚点分节的目录项，点击
// 后音频定位到锚点处的那句，而不是整个 spine 的首句。cue 查找是真的，只拦最终
// 的原生 seek。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart'
    show TtuTocEntry;
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/reader/reader_audiobook_panel.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/utils.dart';

class _RecordingSeekController extends AudiobookPlayerController {
  AudioCue? requestedCue;

  @override
  Future<void> skipToCue(AudioCue cue) async {
    requestedCue = cue;
  }
}

AudioCue _cue(int section, int offset, int startMs) => AudioCue()
  ..bookKey = 'anchor-book'
  ..chapterHref = 'part-$section.xhtml'
  ..sentenceIndex = offset
  ..textFragmentId = SubtitleRematchCodec.encodeHit(
    sectionIndex: section,
    normCharStart: offset,
    normCharEnd: offset + 10,
  )
  ..text = 'Cue at $section/$offset'
  ..startMs = startMs
  ..endMs = startMs + 10000
  ..audioFileIndex = 0;

void main() {
  setUpAll(() => LocaleSettings.setLocale(AppLocale.en));

  for (final bool sameSpine in <bool>[true, false]) {
    testWidgets(
      'chapter click seeks the chosen ${sameSpine ? 'anchored subchapter' : 'spine chapter'}',
      (tester) async {
        tester.view.physicalSize = const Size(600, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final _RecordingSeekController controller = _RecordingSeekController();
        addTearDown(controller.dispose);
        final int secondSection = sameSpine ? 0 : 1;
        final AudioCue first = _cue(0, 0, 0);
        final AudioCue second = _cue(secondSection, 100, 10000);
        controller.setAllBookCues(<AudioCue>[first, second]);
        int? jumpedSection;
        String? jumpedFragment;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              splashFactory: NoSplash.splashFactory,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  return TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          body: ReaderAudiobookPanel(
                            controller: controller,
                            toc: <TtuTocEntry>[
                              const TtuTocEntry(
                                index: 0,
                                label: 'Part One',
                                fragment: 'part-one',
                                anchorCharOffset: 0,
                              ),
                              TtuTocEntry(
                                index: secondSection,
                                label: 'Part Two',
                                fragment: 'part-two',
                                anchorCharOffset: 100,
                              ),
                            ],
                            currentSection: 0,
                            currentCharOffset: 0,
                            onJumpSection: (section, fragment) async {
                              jumpedSection = section;
                              jumpedFragment = fragment;
                            },
                            title: 'Book',
                            chapterLabel: 'Part One',
                            coverPath: null,
                            settingsBuilder: (_) => const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ),
                    child: const Text('Open panel'),
                  );
                },
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open panel'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Part Two'));
        await tester.tap(find.text('Part Two'));
        await tester.pumpAndSettle();
        expect(jumpedSection, secondSection);
        expect(jumpedFragment, 'part-two');
        final AudioCue? selected = controller.requestedCue;
        await tester.pumpWidget(const SizedBox.shrink());
        expect(
          selected,
          same(second),
          reason:
              'Reader navigation correctly selected #part-two at char '
              '100, but audio must not seek back to the first cue of its '
              'shared spine. Actual requested startMs=${selected?.startMs}.',
        );
      },
    );
  }
}
