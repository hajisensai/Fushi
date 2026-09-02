import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  final String source = File(
    'lib/src/pages/implementations/gal_capture_setup_dialog.dart',
  ).readAsStringSync();
  final String page = File(
    'lib/src/pages/implementations/texthooker_page.dart',
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
    final int pop = dismiss.indexOf('Navigator.of(context).maybePop(');
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
    expect(
      RegExp(r'_dismissOnce\(yieldingToRiskConsent:\s*false\)')
          .allMatches(code)
          .length,
      2,
      reason: '用户主动的两条出口（选中线程、关闭按钮）必须显式声明不是让位，'
          '否则会把「已提示过」标记一起回滚，弹窗每来一行台词就弹回来',
    );
  });

  test('查词风险待确认时捕获设置模态框必须主动让位，且让位与用户关闭可区分', () {
    final String build = topLevelFunctionBody(source, 'build')!;
    // topLevelFunctionBody 取文件里第一个同名声明，而本文件有两个 `Widget build`。
    // 钉一个只属于弹窗那个 build 的标志物，避免哪天有人往文件顶部挪进一个 widget
    // 类之后守卫静默锚到别人身上、恒绿。
    expect(
      build.contains('AlertDialog'),
      isTrue,
      reason: '锚点必须是 GalCaptureSetupDialog 的 build，不是同文件另一个 build',
    );
    expect(
      containsIdentifier(build, 'needsUnsafeRiskAcceptance'),
      isTrue,
      reason: '捕获设置弹窗必须监听逐 exe 查词风险门，不能继续挡住工作台确认入口',
    );
    // 原来这里只断言 build 里出现过 `_scheduleAutoClose(`——改动之前就已经为真，
    // 零检出能力。真正要钉的是「让位」与「用户选中线程」用两个不同实参：前者要
    // 回滚「本会话已提示过」，后者不能回滚。
    expect(
      RegExp(r'_scheduleAutoClose\(yieldingToRiskConsent:\s*true\)')
          .allMatches(maskComments(build))
          .length,
      1,
      reason: '风险让位必须声明自己是让位，调用方据此回滚「已提示过」标记，'
          '否则确认完风险后本会话再也拿不到捕获设置弹窗',
    );
    expect(
      RegExp(r'_scheduleAutoClose\(yieldingToRiskConsent:\s*false\)')
          .allMatches(maskComments(build))
          .length,
      1,
      reason: '用户选中线程是用户自己的动作，不得被当成让位回滚标记',
    );
  });

  test('给风险确认让位必须回滚「本会话已提示过」，用户自己关掉的不回滚', () {
    // GalCaptureSetupDialog 全仓只有 texthooker_page 一个构造点，没有手动重开入口。
    // `_captureSetupShownForSession` 在 showAppDialog **之前**就落，而本 PR 新增了
    // 「风险请求把弹窗顶掉」这条**非用户意愿**的出口——不回滚这个标记，用户确认完
    // 风险之后本会话再也拿不到捕获设置弹窗（右栏独有的采集源判读 / 语音轨试听 /
    // BGM 排除全没了）。
    //
    // 反过来也不能无条件回滚：这个标记的唯一用途就是让**用户主动关掉**之后不再被
    // 每来一行台词弹一次（选中线程有自己的判据 selectedTextThreadKey == null，
    // 不靠它）。所以回滚必须**恰好**被让位出口门控。
    final String code = maskComments(page);
    expect(
      RegExp(r'_captureSetupShownForSession = sessionStartedAt;')
          .allMatches(code)
          .length,
      1,
    );
    expect(
      code.contains(
        'if (outcome == GalCaptureSetupOutcome.yieldedToRiskConsent) {',
      ),
      isTrue,
      reason: '让位出口必须回滚「已提示过」，否则风险确认完本会话再无捕获设置弹窗',
    );
    expect(
      RegExp(r'_captureSetupShownForSession = null;').allMatches(code).length,
      1,
      reason: '只许这一条出口回滚；无条件回滚会让用户主动关掉的弹窗每行都弹回来',
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
