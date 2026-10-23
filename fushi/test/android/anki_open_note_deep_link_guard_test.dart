import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_view_model.dart'
    show ankiRepositoryChainLabel;
import 'package:fushi/src/anki/delegating_anki_repository.dart';
import 'package:fushi_anki/fushi_anki.dart';

import '../helpers/source_guard.dart';

/// 反馈 6lORfLyhXd：AnkiDroid 上「明明制过卡，却无法从 Fushi 打开 Anki 卡片」。
///
/// 原生 `openNote` 是 Android 平台边界（`startActivity` 起 AnkiDroid 的浏览器深链），
/// widget / 单元测试够不到；能落地的最强层是源码守卫，钉住两条：
/// 1. 深链钉到我们制卡写入的那个 AnkiDroid 包（`AnkiDroidTarget.resolve`）——note id
///    只存在于那份 collection 里；
/// 2. 以 `startActivity` + `ActivityNotFoundException` 为准，不再先问
///    `resolveActivity`——后者受包可见性与厂商解析策略影响，误报 null 时我们一次都
///    没试就报「打不开」。
void main() {
  String openNoteBody() {
    final String src = maskComments(
      File(
        'android/app/src/main/java/app/fushi/reader/AnkiChannelHandler.java',
      ).readAsStringSync(),
    );
    final int start = src.indexOf('private boolean openNote(long noteId)');
    expect(start, greaterThan(0), reason: 'openNote 改名了？守卫锚点失效');
    final int end = src.indexOf('\n    }\n', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);
    expect(body, contains('x-callback-url/browser'), reason: '切错了方法体');
    return body;
  }

  test('深链钉到制卡写入的那个 AnkiDroid 包', () {
    final String body = openNoteBody();
    expect(body, contains('AnkiDroidTarget.resolve(context)'));
    expect(body, contains('intent.setPackage(target.packageName)'));
  });

  test('以 startActivity 为准，不再用 resolveActivity 预判', () {
    final String body = openNoteBody();
    expect(body.contains('resolveActivity'), isFalse);
    expect(body, contains('context.startActivity(intent)'));
    expect(body, contains('catch (ActivityNotFoundException'));
  });

  test('弹窗 ↗ 打不开时留诊断日志（带后端装饰链）', () {
    final String src = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ).readAsStringSync();
    expect(src, contains("'DictPopupWebview.openInAnki',"));
    expect(src, contains('ankiRepositoryChainLabel('));
  });

  test('ankiRepositoryChainLabel 从外到内列出装饰链', () {
    final BaseAnkiRepository inner = _Leaf();
    expect(ankiRepositoryChainLabel(inner), '_Leaf');
    expect(
      ankiRepositoryChainLabel(_Wrap(_Wrap(inner))),
      '_Wrap > _Wrap > _Leaf',
    );
  });
}

class _Leaf implements BaseAnkiRepository {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Wrap extends DelegatingAnkiRepository {
  _Wrap(BaseAnkiRepository inner) : super(inner: inner);
}
