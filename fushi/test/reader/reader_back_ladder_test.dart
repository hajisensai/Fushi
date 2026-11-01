import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_back_ladder.dart';

/// 阅读器返回阶梯（NJIIDAhIZL）：系统返回在歌词模式下直接退书，Esc 先退歌词。
void main() {
  ReaderBackStep step(
    ReaderBackSource source, {
    bool dictionaryShown = false,
    bool lyricsMode = false,
    bool explicitExit = false,
  }) => resolveReaderBackStep(
    source: source,
    dictionaryShown: dictionaryShown,
    lyricsMode: lyricsMode,
    explicitExit: explicitExit,
  );

  group('路由返回（Android 返回键 / 侧滑、iOS 侧滑、根 maybePop）', () {
    test('歌词模式下直接退书（不再先掀开歌词层）', () {
      expect(
        step(ReaderBackSource.route, lyricsMode: true),
        ReaderBackStep.exitBook,
      );
    });

    test('词典弹窗开着先关弹窗——歌词模式下也一样', () {
      expect(
        step(ReaderBackSource.route, dictionaryShown: true),
        ReaderBackStep.closeDictionary,
      );
      expect(
        step(ReaderBackSource.route, dictionaryShown: true, lyricsMode: true),
        ReaderBackStep.closeDictionary,
      );
    });

    test('正文无浮层时退书', () {
      expect(step(ReaderBackSource.route), ReaderBackStep.exitBook);
    });

    test('显式退书在途时跳过整条阶梯', () {
      expect(
        step(
          ReaderBackSource.route,
          dictionaryShown: true,
          lyricsMode: true,
          explicitExit: true,
        ),
        ReaderBackStep.exitBook,
      );
    });
  });

  group('globalBack 快捷键（Esc / Alt+← / 手柄 B）', () {
    test('歌词模式下先掀开歌词层，留在书里', () {
      expect(
        step(ReaderBackSource.shortcut, lyricsMode: true),
        ReaderBackStep.closeLyrics,
      );
    });

    test('词典弹窗优先于歌词层', () {
      expect(
        step(
          ReaderBackSource.shortcut,
          dictionaryShown: true,
          lyricsMode: true,
        ),
        ReaderBackStep.closeDictionary,
      );
    });

    test('正文无浮层时退书', () {
      expect(step(ReaderBackSource.shortcut), ReaderBackStep.exitBook);
    });
  });
}
