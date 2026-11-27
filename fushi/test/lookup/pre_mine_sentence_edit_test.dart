import 'dart:convert';
import 'dart:io';

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/overlay_bridge_handlers.dart';
import 'package:fushi/src/lookup/pre_mine_sentence_edit.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show MiningRequestOverrides;

import '../helpers/source_guard.dart';

/// 反馈 uEnwXmBIR0：应用外查词卡「编辑例句后制卡」。标记随 `miningOverrides` 上来，
/// 宿主在派发制卡前弹编辑框，改好的句子写回 `fields['sentence']` 并打「手改」标记。
/// 委托路径上宿主不碰 AppModel 的任何成员（碰了就说明走错了路）。
class _UntouchedModel implements AppModel {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('AppModel.${invocation.memberName} touched');
}

/// 经共享桥发一次 mineEntry，回收回包与委托收到的 fields。
Future<({Map<String, Object?> reply, List<Map<String, String>> mined})>
_mineThroughBridge(
  Map<String, String> fields, {
  required PreMineSentenceEditor? editor,
  String sentenceContext = '',
}) async {
  final List<Map<String, String>> mined = <Map<String, String>>[];
  final Completer<Object?> replied = Completer<Object?>();
  final bool handled = maybeHandleOverlayDeferredBridge(
    model: _UntouchedModel(),
    handler: 'mineEntry',
    message: <String, Object?>{
      '__bridgeId': 7,
      'args': <Object?>[fields],
    },
    resolveBridge: (int id, Object? value) async => replied.complete(value),
    sentenceContext: sentenceContext,
    miningHandler:
        ({required Map<String, String> fields, int? updateNoteId}) async {
          mined.add(fields);
          return <String, Object?>{'ankiConnect': false, 'noteId': null};
        },
    preMineSentenceEditor: editor,
  );
  expect(handled, isTrue);
  final Object? value = await replied.future.timeout(
    const Duration(seconds: 10),
  );
  return (
    reply: (value! as Map<Object?, Object?>).cast<String, Object?>(),
    mined: mined,
  );
}

void main() {
  const Map<String, String> base = <String, String>{
    'expression': '猫',
    'sentence': '吾輩は猫である',
  };

  test('没请求编辑：原样返回，不弹编辑框', () async {
    int asked = 0;
    final Map<String, String>? out = await applyPreMineSentenceEdit(
      base,
      initialSentence: '吾輩は猫である',
      editor: (String s) async {
        asked++;
        return s;
      },
    );
    expect(out, same(base));
    expect(asked, 0);
    expect(preMineSentenceEditRequested(base), isFalse);
  });

  test('请求编辑：编辑框拿到原句，改好的句子写回并打手改标记、摘掉请求标记', () async {
    final Map<String, String> fields = debugFieldsRequestingSentenceEdit(base);
    expect(preMineSentenceEditRequested(fields), isTrue);
    final List<String> shown = <String>[];
    final Map<String, String>? out = await applyPreMineSentenceEdit(
      fields,
      initialSentence: '吾輩は猫である',
      editor: (String s) async {
        shown.add(s);
        return '吾輩は猫である。名前はまだ無い。';
      },
    );
    expect(shown, <String>['吾輩は猫である']);
    expect(out!['sentence'], '吾輩は猫である。名前はまだ無い。');
    expect(editedMineSentenceOf(out), '吾輩は猫である。名前はまだ無い。');
    expect(out.containsKey(MiningRequestOverrides.wireKey), isFalse);
    expect(preMineSentenceEditRequested(out), isFalse);
  });

  test('编辑框里取消：返回 null（这张卡不制）', () async {
    final Map<String, String>? out = await applyPreMineSentenceEdit(
      debugFieldsRequestingSentenceEdit(base),
      initialSentence: '吾輩は猫である',
      editor: (String s) async => null,
    );
    expect(out, isNull);
  });

  test('其余覆盖项（调整句子音频的起止）原样保留', () async {
    final Map<String, String>? out = await applyPreMineSentenceEdit(
      debugFieldsRequestingSentenceEdit(
        base,
        otherOverrides: <String, Object?>{'audioStartDeltaMs': -300},
      ),
      initialSentence: '吾輩は猫である',
      editor: (String s) async => s,
    );
    final Map<String, Object?> overrides =
        jsonDecode(out![MiningRequestOverrides.wireKey]!)
            as Map<String, Object?>;
    expect(overrides, <String, Object?>{'audioStartDeltaMs': -300});
    expect(MiningRequestOverrides.readFrom(out)?.audioStartDeltaMs, -300);
  });

  test('宿主给不出编辑框：只摘标记、照常制卡（不吞掉这次点击）', () async {
    final Map<String, String>? out = await applyPreMineSentenceEdit(
      debugFieldsRequestingSentenceEdit(base),
      initialSentence: '吾輩は猫である',
      editor: null,
    );
    expect(out!['sentence'], '吾輩は猫である');
    expect(editedMineSentenceOf(out), isNull);
    expect(preMineSentenceEditRequested(out), isFalse);
  });

  group('共享桥（桌面覆盖窗各表面共用）', () {
    test('编辑后交给表面的制卡委托：例句是改过的、带手改标记，截图 / 音频由委托照旧带', () async {
      final List<String> shown = <String>[];
      final result = await _mineThroughBridge(
        debugFieldsRequestingSentenceEdit(<String, String>{'expression': '猫'}),
        sentenceContext: '吾輩は猫である',
        editor: (String s) async {
          shown.add(s);
          return '吾輩は猫である。';
        },
      );
      expect(shown, <String>['吾輩は猫である'], reason: '编辑框从宿主的句子上下文起步');
      expect(result.mined, hasLength(1));
      expect(result.mined.single['sentence'], '吾輩は猫である。');
      expect(editedMineSentenceOf(result.mined.single), '吾輩は猫である。');
    });

    test('编辑框里取消：回 cancelled，委托一次都不调', () async {
      final result = await _mineThroughBridge(
        debugFieldsRequestingSentenceEdit(<String, String>{'expression': '猫'}),
        editor: (String s) async => null,
      );
      expect(result.reply['cancelled'], isTrue);
      expect(result.mined, isEmpty);
    });

    test('普通「+」不弹编辑框', () async {
      int asked = 0;
      final result = await _mineThroughBridge(
        <String, String>{'expression': '猫'},
        editor: (String s) async {
          asked++;
          return s;
        },
      );
      expect(asked, 0);
      expect(result.mined, hasLength(1));
    });
  });

  group('popup.js 入口', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();

    test('只在宿主注入 __fushiPreMineSentenceEdit 且「+」渲染时建按钮', () {
      expect(
        js,
        contains(
          'if (miningEnabled && window.__fushiPreMineSentenceEdit === true) {\n'
          '        buttonsContainer.appendChild(buildSentenceEditButton());',
        ),
      );
    });

    test('回点同一颗「+」带上 editSentence 标记（不另起制卡桥）', () {
      final int start = js.indexOf('function buildSentenceEditButton() {');
      expect(start, greaterThanOrEqualTo(0));
      final String body = js.substring(start, js.indexOf('\n}\n', start));
      expect(
        body,
        contains(
          'window.fushiPopupMineEntryByIndex(\n'
          '                __fushiEntryIndexOf(button), '
          '{ $kPreMineSentenceEditKey: true });',
        ),
      );
      expect(body, isNot(contains("callHandler('mineEntry'")));
    });
  });

  group('覆盖窗入口按表面门控', () {
    // flutter test 的 cwd 是 fushi 包根。
    String read(String path) => compactCode(File(path).readAsStringSync());
    final String controller = read(
      'lib/src/lookup/global_lookup_controller.dart',
    );
    final String render = read('lib/src/lookup/global_lookup_render.dart');
    final String injection = read(
      'lib/src/pages/implementations/popup_settings_injection.dart',
    );

    test('游戏内查词卡（galCard）借不了主窗：不渲染入口，桥上也不给编辑出口', () {
      expect(
        controller,
        contains(
          "bool_preMineSentenceEditAvailable(GlobalLookupRouteroute)=>route.source!='galCard';",
        ),
      );
      // 渲染门控与桥上的编辑出口共用同一处判据。
      expect(
        controller,
        contains('preMineSentenceEdit:_preMineSentenceEditAvailable(route),'),
      );
      expect(
        controller,
        contains(
          'preMineSentenceEditor:_preMineSentenceEditAvailable(GlobalLookupChannel.currentRoute)?_editMineSentenceInMainWindow:null,',
        ),
      );
    });

    test('门控走每帧 renderJs、在 renderPopup 之前写，不进静态段', () {
      final int flag = render.indexOf(
        r'window.__fushiPreMineSentenceEdit=$preMineSentenceEdit;',
      );
      expect(flag, greaterThan(0));
      expect(
        render.indexOf('window.renderPopup&&window.renderPopup();'),
        greaterThan(flag),
      );
      expect(injection, isNot(contains('window.__fushiPreMineSentenceEdit=')));
      expect(injection, contains('t.popup_sentence_edit_button'));
    });
  });
}
