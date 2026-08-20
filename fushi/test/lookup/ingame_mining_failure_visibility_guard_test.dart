// BUG-1734 的守卫：游戏内卡片制卡失败时不得静默。
//
// 为什么是源码守卫而不是行为测试：失败反馈走 `FushiToast.show`，它是个没有注入点的
// static，桌面路径还依赖全局 navigatorKey；在 widget 测试里既观察不到也无法替身，
// 硬测只能测到"没抛异常"，恰好是这条 bug 原本的样子。所以这里锚的是**顺序不变量**：
// 在 `_ingameMiningHandlerFor` 里，那条返回 `ankiConnect: false` 的失败分支之前必须先
// 有一次 `FushiToast.show(`。
//
// 这条不变量对应一个真机实测的用户可见后果：2026-08-19 在《天使☆嚣嚣 RE-BOOT!》上，
// 游戏内查词一切正常（卡片已画进游戏图层、点击已转发），点「制卡」后**屏幕上零反馈**、
// Anki 一条都没多；popup 侧收到 ankiConnect:false 同样什么都不做
// （assets/popup/popup.js 的 mine 分支只在 ankiConnect 为真时才有动作），
// 于是用户无法区分"制卡失败了"和"我没点到按钮"。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

const String _controllerPath =
    'lib/src/lookup/gal_hook_text_overlay_controller.dart';
const String _handlerSignature =
    'OverlayMiningHandler _ingameMiningHandlerFor(';
const String _toastCall = 'FushiToast.show(';
const String _failureReturn = "'ankiConnect': false";

/// 返回失败分支相对于 toast 的位置关系；`null` 表示这段源码里根本没有失败分支。
({int toastAt, int failureAt})? _failurePathOffsets(String handlerBody) {
  final int failureAt = handlerBody.indexOf(_failureReturn);
  if (failureAt < 0) return null;
  return (toastAt: handlerBody.indexOf(_toastCall), failureAt: failureAt);
}

List<String> findSilentIngameMiningFailure(String handlerBody) {
  final ({int toastAt, int failureAt})? offsets =
      _failurePathOffsets(handlerBody);
  if (offsets == null) {
    return <String>[
      '_ingameMiningHandlerFor 里找不到 ankiConnect:false 失败分支，'
          '守卫锚点已失效——请重新确认失败路径在哪里，不要直接删掉本测试',
    ];
  }
  if (offsets.toastAt < 0) {
    return <String>[
      '_ingameMiningHandlerFor 的失败分支没有任何 $_toastCall：'
          '制卡失败会完全静默（popup 侧对 ankiConnect:false 也不做任何事）',
    ];
  }
  if (offsets.toastAt > offsets.failureAt) {
    return <String>[
      '_ingameMiningHandlerFor 里 $_toastCall 排在失败返回之后：'
          '这条 return 之后的代码不会执行',
    ];
  }
  return <String>[];
}

void main() {
  group('BUG-1734 游戏内制卡失败必须可见', () {
    test('真文件：失败分支先 toast 再返回', () {
      final String src = File(_controllerPath).readAsStringSync();
      final String body = methodBody(src, _handlerSignature);
      expect(findSilentIngameMiningFailure(body), isEmpty);
    });

    test('真文件：两种失败原因分开报（没有台词 / 对不上当前这句）', () {
      final String src = File(_controllerPath).readAsStringSync();
      final String body = maskComments(methodBody(src, _handlerSignature));
      // 用户要做的动作完全不同：换线程 vs 重新点这一句。共用一条文案等于没分。
      expect(
        body.contains('game_hook_mining_no_session_lines'),
        isTrue,
        reason: '「本局一条台词都没有」必须有自己的文案，指向工作台换线程',
      );
      expect(
        body.contains('game_hook_line_unavailable'),
        isTrue,
        reason: '「有台词但对不上」沿用浮窗点词路径的同一条文案',
      );
    });
  });

  group('变异自证：脏输入必须红', () {
    const String silent = '''
{
  return ({required Map<String, String> fields, int? updateNoteId}) async {
    final String? resolved = _resolveIngameMiningLineId(line);
    if (resolved == null) {
      return const <String, Object?>{'ankiConnect': false, 'noteId': null};
    }
    return _mineFromLookup(lineId: resolved);
  };
}
''';

    const String toastAfterReturn = '''
{
  return ({required Map<String, String> fields, int? updateNoteId}) async {
    final String? resolved = _resolveIngameMiningLineId(line);
    if (resolved == null) {
      return const <String, Object?>{'ankiConnect': false, 'noteId': null};
    }
    FushiToast.show(msg: t.game_hook_line_unavailable);
    return _mineFromLookup(lineId: resolved);
  };
}
''';

    const String clean = '''
{
  return ({required Map<String, String> fields, int? updateNoteId}) async {
    final String? resolved = _resolveIngameMiningLineId(line);
    if (resolved == null) {
      FushiToast.show(msg: t.game_hook_line_unavailable);
      return const <String, Object?>{'ankiConnect': false, 'noteId': null};
    }
    return _mineFromLookup(lineId: resolved);
  };
}
''';

    test('完全没有 toast 判红', () {
      expect(findSilentIngameMiningFailure(silent), isNotEmpty);
    });

    test('toast 排在失败返回之后判红', () {
      expect(findSilentIngameMiningFailure(toastAfterReturn), isNotEmpty);
    });

    test('先 toast 再返回保持绿', () {
      expect(findSilentIngameMiningFailure(clean), isEmpty);
    });

    test('锚点失效（找不到失败分支）判红，而不是静静通过', () {
      expect(findSilentIngameMiningFailure('{ return 1; }'), isNotEmpty);
    });
  });
}
