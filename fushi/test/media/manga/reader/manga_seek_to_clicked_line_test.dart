import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/manga_fushi_page.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 反馈 RCsvzByem-：有声漫画也要能「点一句跳过去播」。鼠标那条路借用有声书的
/// 「跳到点击句」绑定（默认中键，与小说阅读器 / 歌词页同一个判据），但漫画页自己
/// 的鼠标绑定优先——同一个键绑了漫画动作就让位，一次按下不能既翻页又跳句。
void main() {
  FushiShortcutRegistry registry() =>
      FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  test('默认绑定：中键归「跳到点击句」，右键（菜单）与左键不归', () {
    final FushiShortcutRegistry reg = registry();
    expect(MangaFushiPage.seekToClickedLineClaimsButton(reg, 1), isTrue);
    expect(MangaFushiPage.seekToClickedLineClaimsButton(reg, 2), isFalse);
    expect(MangaFushiPage.seekToClickedLineClaimsButton(reg, 0), isFalse);
    expect(MangaFushiPage.seekToClickedLineClaimsButton(reg, -1), isFalse);
  });

  test('漫画页把同一个键绑给别的动作时让位', () {
    final FushiShortcutRegistry reg = registry()
      ..updateBinding(
        ShortcutAction.mangaPageForward,
        const ShortcutBindingSet(
          mouseBindings: <MouseBinding>[MouseBinding(1)],
        ),
      );
    expect(MangaFushiPage.seekToClickedLineClaimsButton(reg, 1), isFalse);
  });

  test('「跳到点击句」改绑到侧键：侧键归它，中键不再归', () {
    final FushiShortcutRegistry reg = registry()
      ..updateBinding(
        ShortcutAction.audiobookSeekToClickedSentence,
        const ShortcutBindingSet(
          mouseBindings: <MouseBinding>[MouseBinding(3)],
        ),
      );
    expect(MangaFushiPage.seekToClickedLineClaimsButton(reg, 3), isTrue);
    expect(MangaFushiPage.seekToClickedLineClaimsButton(reg, 1), isFalse);
  });
}
