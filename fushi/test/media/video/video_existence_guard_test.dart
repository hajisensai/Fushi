import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-897 源码守卫：防止后续重构把「load 前本地存在性校验」删掉，回归无限转圈。
///
/// 断言 `_applyLoad` 方法体内、`controller.load(` 调用之前存在
/// `isLocalVideoResourceMissing(` 短路；以及缺失态 spinner 短路与缺失对话框复用既有
/// 删除序列。纯字符串静态守卫，不跑 libmpv。
void main() {
  const String pagePath =
      'lib/src/pages/implementations/video_fushi_page.dart';
  late String source;

  setUpAll(() {
    source = File(pagePath).readAsStringSync().replaceAll('\r\n', '\n');
  });

  String applyLoadBody() {
    final int start = source.indexOf('Future<void> _applyLoad(');
    expect(start, greaterThanOrEqualTo(0), reason: '_applyLoad 必须存在');
    // 取到下一个同级方法签名前（_promptMissingResource 紧随其后）。
    final int end = source.indexOf('Future<void> _promptMissingResource(');
    expect(end, greaterThan(start));
    return source.substring(start, end);
  }

  test('_applyLoad 在 controller.load 之前调本地存在性校验', () {
    final String body = applyLoadBody();
    final int checkAt = body.indexOf('isLocalVideoResourceMissing(');
    final int loadAt = body.indexOf('controller.load(');
    expect(checkAt, greaterThanOrEqualTo(0), reason: '缺存在性校验 → 文件缺失会无限转圈');
    expect(loadAt, greaterThan(checkAt),
        reason: '存在性校验必须在 controller.load 之前短路');
  });

  test('缺失态 _missingResource 在 spinner 判据之前短路', () {
    // build 域内 _missingResource 分支必须在「加载中转圈」判据之前
    // （否则缺失时 _controller==null 仍落进加载分支无限转）。
    // TODO-1213 起裸 `CircularProgressIndicator()` 被有上下文的 `_buildLoadingBody()`
    // （渲染 VideoLoadingOverlay，内部仍是转圈）替代，故加载分支的稳定标记改用
    // `_buildLoadingBody()` 调用点；顺序契约（缺失分支必须在加载分支前）不变。
    final int branchAt = source.indexOf(': _missingResource');
    final int loadingAt = source.indexOf('_buildLoadingBody()');
    expect(branchAt, greaterThanOrEqualTo(0),
        reason: 'build 必须有 _missingResource 分支');
    expect(loadingAt, greaterThan(branchAt),
        reason: '_missingResource 分支必须在加载转圈判据之前（否则仍无限转圈）');
  });

  test('缺失态删除复用既有删除序列 + 二次确认', () {
    // 守的是「不要在缺失态另写一套删除」。三步（删行 → 回收 app-owned 资产 →
    // 压缩）已从页面收进仓储的单一入口 deleteVideoBookAndReclaimAssets，页面只
    // 调它一处；断言因此拆成两半，避免盯着页面里那三行字面量、被一次正当的收口
    // 重构撞成假红，也避免只认入口名而放过「入口自己少做了一步」。
    expect(source.contains('deleteVideoBookAndReclaimAssets('), isTrue,
        reason: '缺失态删除必须复用仓储的完整删除入口，不得在页面另写删除序列');

    final String repo = File(
      'lib/src/media/video/video_book_repository.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    const String implSignature =
        'Future<int> _deleteVideoBooksAndReclaimAssetsUnlocked(';
    final int implAt = repo.indexOf(implSignature);
    expect(implAt, greaterThanOrEqualTo(0),
        reason: '删除入口的实现体消失了；改名了就同步改本守卫');
    // 必须把范围夹到**方法体内**：截到文件末尾的话，后面那些方法的**定义行**
    // （`Future<void> compactAfterVideoDeleteBestEffort()`）会让 contains 恒真，
    // 断言变空——实测把调用删掉后守卫照样绿，就是这么发现的。
    final int implEnd = repo.indexOf(RegExp(r'\n  (?:///|Future<|@)'),
        implAt + implSignature.length);
    expect(implEnd, greaterThan(implAt),
        reason: '找不到删除入口实现体的结尾（下一个同级成员）');
    final String impl = repo.substring(implAt, implEnd);
    for (final String step in <String>[
      'deleteVideoBook(',
      '_reclaimDeletedVideoBookAssetsUnlocked(',
      'compactAfterVideoDeleteBestEffort(',
    ]) {
      expect(impl.contains(step), isTrue,
          reason: '删除入口少了「$step」这一步——缺失态删除会留下 app-owned 残留');
    }

    // 二次确认走既有 video_delete_confirm。
    expect(source.contains('video_delete_confirm'), isTrue);
    // 中性缺失文案 key。
    expect(source.contains('video_resource_missing_message'), isTrue);
  });
}
