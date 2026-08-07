import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

/// Source-scan guard: the lyrics-mode focus caret stays wired into the reader
/// page. JS runtime behaviour is covered by device integration tests; this
/// keeps the Dart plumbing from silently regressing.
///
/// TODO-387: the `CaretSurface` enum moved into the shared
/// [DictionaryCaretController]; this guard now asserts the enum lives there and
/// that the reader re-exports it, while the lyrics-specific JS wiring stays in
/// the reader page.
void main() {
  final String src = readReaderPageSource();
  final String controller = File(
    'lib/src/shortcuts/dictionary_caret_controller.dart',
  ).readAsStringSync();

  test('CaretSurface (with a lyrics value) lives in the shared controller', () {
    // 断的是**契约**（枚举住在共享控制器里、且带 lyrics 这个面）而不是整行字面量：
    // 原写法 contains('enum CaretSurface { ... lyrics }') 在 PR#632 给枚举追加
    // video 面时当场红，可语义一点没坏——锚点把「值域快照」误当成了不变量。
    // 改成解析值集合后做 containsAll：新增面不再误伤，删掉 lyrics /
    // 把枚举搬走仍然当场红。
    final Match? decl =
        RegExp(r'enum\s+CaretSurface\s*\{([^}]*)\}').firstMatch(controller);
    expect(decl, isNotNull,
        reason: 'CaretSurface 枚举必须声明在共享的 dictionary_caret_controller.dart 里');
    final Set<String> values = decl!
        .group(1)!
        .split(',')
        .map((String v) => v.trim())
        .where((String v) => v.isNotEmpty)
        .toSet();
    expect(
      values,
      containsAll(<String>['none', 'reader', 'popup', 'lyrics']),
      reason: '共享 caret 状态机至少要覆盖 none/reader/popup/lyrics 四个面',
    );
  });

  test('reader re-exports CaretSurface so its references still resolve', () {
    expect(
      src,
      contains(
        "export 'package:fushi/src/shortcuts/dictionary_caret_controller.dart'",
      ),
    );
    expect(src, contains('show CaretSurface;'));
  });

  test('lyrics page load injects the lyrics caret', () {
    expect(src, contains('ReaderLyricsCaretScripts.source()'));
    expect(src, contains('ReaderLyricsCaretScripts.initInvocation('));
  });

  test('enter/exit toggle the playback-follow suppression flag', () {
    expect(src, contains('window.__lyricsCaretActive = true;'));
    expect(src, contains('window.__lyricsCaretActive = false;'));
  });

  test('caret actions branch to the lyrics caret', () {
    expect(src, contains('ReaderLyricsCaretScripts.moveInvocation'));
    expect(src, contains('ReaderLyricsCaretScripts.lookupInvocation'));
    expect(src, contains('_caretOnLyrics'));
  });

  test('leaving lyrics mode resets the caret surface', () {
    expect(src, contains('if (_caretSurface == CaretSurface.lyrics)'));
  });
}
