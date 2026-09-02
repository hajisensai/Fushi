import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  final String source = File(
    'lib/src/pages/implementations/gal_capture_setup_dialog.dart',
  ).readAsStringSync();

  test('捕获设置弹窗的所有关闭路径收口到一次性 dismiss', () {
    final String code = maskComments(source);
    expect(
      RegExp(r'Navigator\.of\(context\)\.(?:maybePop|pop)\s*\(')
          .allMatches(code)
          .length,
      1,
      reason: '选择成功、状态监听和关闭按钮不能各自 pop，否则会弹掉底层页面',
    );

    final String dismiss = topLevelFunctionBody(source, '_dismissOnce')!;
    final int guard = dismiss.indexOf('if (_dismissRequested) return;');
    final int latch = dismiss.indexOf('_dismissRequested = true;');
    final int pop = dismiss.indexOf('Navigator.of(context).maybePop()');
    expect(guard, greaterThanOrEqualTo(0));
    expect(latch, greaterThan(guard));
    expect(pop, greaterThan(latch));

    expect(
      containsIdentifierCall(
        topLevelFunctionBody(source, '_selectThread')!,
        '_dismissOnce',
      ),
      isTrue,
    );
    expect(
      containsIdentifierCall(
        topLevelFunctionBody(source, '_scheduleAutoClose')!,
        '_dismissOnce',
      ),
      isTrue,
    );
    expect(code.contains('onPressed: _dismissOnce'), isTrue);
  });

  test('查词风险待确认时捕获设置模态框必须主动让位', () {
    final String build = topLevelFunctionBody(source, 'build')!;
    expect(
      containsIdentifier(build, 'needsUnsafeRiskAcceptance'),
      isTrue,
      reason: '捕获设置弹窗必须监听逐 exe 查词风险门，不能继续挡住工作台确认入口',
    );
    expect(
      containsIdentifierCall(build, '_scheduleAutoClose'),
      isTrue,
      reason: '风险门出现后必须沿既有一次性关闭出口让位，不能直接重复 pop',
    );
  });

  test('音轨试听串行化并以最后一次请求代次裁决', () {
    final String request = topLevelFunctionBody(source, '_requestPreview')!;
    final String toggle = topLevelFunctionBody(source, '_togglePreview')!;
    expect(containsIdentifier(request, '_previewGeneration'), isTrue);
    expect(containsIdentifier(request, '_previewQueue'), isTrue);
    expect(containsIdentifierCall(request, '_togglePreview'), isTrue);
    expect(
      RegExp(r'generation\s*!=\s*_previewGeneration')
          .allMatches(maskCommentsAndStrings(toggle))
          .length,
      greaterThanOrEqualTo(2),
      reason: '导出前后都必须拒绝过期请求，异步逆序返回不能覆盖最后一次点击',
    );
  });
}
