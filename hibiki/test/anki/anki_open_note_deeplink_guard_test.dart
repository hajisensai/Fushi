import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// BUG-891 守卫：AnkiDroid「在 Anki 中打开这张卡片」必须走 Card Browser 深链，
/// 不能再用永远无 activity 处理的 note ContentProvider URI 的 ACTION_VIEW。
///
/// 根因：旧实现 `new Intent(ACTION_VIEW, content://com.ichi2.anki.flashcards/notes/<id>)`
/// 依赖 AnkiDroid 注册一个响应该 note URI / mimeType 的 activity——但 AnkiDroid
/// 没有任何 exported activity 过滤它（该 URI 只被 ContentProvider 服务），故
/// `resolveActivity` 恒为 null → openNote 返回 false → 弹「无法在 Anki 中打开这张
/// 卡片。」。唯一受支持的深链是 exported 的 `CardBrowserDeepLink` 别名：
/// `anki://x-callback-url/browser?search=nid:<id>`（search 参数直接喂给浏览器）。
void main() {
  final java = File(
    'android/app/src/main/java/app/hibiki/reader/AnkiChannelHandler.java',
  ).readAsStringSync();

  final openNote = _extractMethodBody(java, 'private boolean openNote(');

  group('AnkiDroid openNote uses the Card Browser deep link (BUG-891)', () {
    test('builds the anki://x-callback-url/browser?search= deep link', () {
      expect(
        openNote.contains('anki://x-callback-url/browser?search='),
        isTrue,
        reason: 'must open via the exported CardBrowserDeepLink alias',
      );
      expect(
        openNote.contains('nid:'),
        isTrue,
        reason: 'search query must target the note id (nid:<id>)',
      );
    });

    test('no longer relies on the note ContentProvider URI ACTION_VIEW', () {
      expect(
        openNote.contains('Note.CONTENT_URI'),
        isFalse,
        reason: 'the note content URI has no activity to VIEW it — '
            'resolveActivity would always return null',
      );
    });

    test('still guards with resolveActivity so old AnkiDroid degrades to false',
        () {
      expect(openNote.contains('resolveActivity'), isTrue);
      expect(openNote.contains('return false'), isTrue);
      expect(openNote.contains('startActivity'), isTrue);
    });
  });
}

/// 从 Java 源码里截出以 [signature] 起始的方法体（到配平的收尾大括号），
/// 让断言只针对该方法，避免命中文件别处的注释/其它方法。
/// 纯函数——不用 `expect`（会在 test 外抛 OutsideTestException），越界即抛 StateError。
String _extractMethodBody(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) throw StateError('method $signature not found');
  final braceOpen = source.indexOf('{', start);
  if (braceOpen < 0) throw StateError('no opening brace after $signature');
  var depth = 0;
  for (var i = braceOpen; i < source.length; i++) {
    final ch = source[i];
    if (ch == '{') depth++;
    if (ch == '}') {
      depth--;
      if (depth == 0) return source.substring(start, i + 1);
    }
  }
  throw StateError('unbalanced braces after $signature');
}
