import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 拍板台 rf--UcsGta 守卫：应用外查词开了「抓取上下文」时，抓到的整段文本一路带到
/// 承接它的查词页，查词页结果区的高级制卡据此给句子分区（前后句加减），而且走的是
/// 既有的 [AdvancedMiningSentenceSection] 契约、同一个对话框。
///
/// 守的是接线：任何一环断了（控制器不再把切好的句子交给主窗出口、排队器丢掉它、
/// 查词页不再把分区接到结果区的开窗函数上、mixin 不再把表面级分区并进对话框），
/// 功能就会静默退回「没有前后句」，单元测试抓不到。
void main() {
  // flutter test 的 cwd 是 fushi 包根。
  final String controller = compactCode(
    File('lib/src/lookup/global_lookup_controller.dart').readAsStringSync(),
  );
  final String capture = compactCode(
    File('lib/src/lookup/selection_capture_ffi.dart').readAsStringSync(),
  );
  final String appModel = compactCode(
    File('lib/src/models/app_model.dart').readAsStringSync(),
  );
  final String home = compactCode(
    File(
      'lib/src/pages/implementations/home_dictionary_page.dart',
    ).readAsStringSync(),
  );
  final String mixin = compactCode(
    File(
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    ).readAsStringSync(),
  );

  test('抓取结果把整段缓冲切成前后句（同一个切句器）', () {
    expect(capture, contains('sentences:splitCapturedContext('));
    expect(capture, contains('maxExpand:maxExpand'));
  });

  test('全局热键的主窗出口把抓到的前后句交给查词页', () {
    expect(controller, contains('sentences=ctx.sentences;'));
    expect(
      controller,
      contains('model.queueExternalLookup(text,capturedContext:sentences);'),
    );
    expect(
      appModel,
      contains('triggerLookup(text,capturedContext:capturedContext,)'),
    );
  });

  test('查词页把抓取上下文接到结果区的高级制卡句子分区', () {
    expect(home, contains('_capturedContext=request.capturedContext;'));
    expect(home, contains('sentenceSection:_capturedSentenceSection,'));
    expect(
      home,
      contains('capturedContextSentenceSection(draft:_capturedDraft'),
    );
    // 制卡落卡读同一份草稿合成的句子。
    expect(home, contains('_capturedDraft.composeText(context.current)'));
  });

  test('mixin 把表面级句子分区并进同一个高级制卡对话框', () {
    expect(
      mixin,
      contains(
        'withSurfaceSentenceSection(awaitbuildAdvancedMiningSections(matched:matched),sentenceSection?.call(),)',
      ),
    );
  });
}
