import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-897 源码守卫：防止后续重构把「load 前本地存在性校验」删掉，回归无限转圈。
///
/// 断言 `_applyLoad` 方法体内、`controller.load(` 调用之前存在
/// `isLocalVideoResourceMissing(` 短路；以及缺失态 spinner 短路与缺失对话框复用既有
/// 删除序列。纯字符串静态守卫，不跑 libmpv。
void main() {
  const String pagePath =
      'lib/src/pages/implementations/video_hibiki_page.dart';
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
    // build 域内 _missingResource 分支必须在 CircularProgressIndicator 转圈判据之前
    // （否则缺失时 _controller==null 仍落进转圈分支无限转）。
    final int branchAt = source.indexOf(': _missingResource');
    final int spinnerAt = source.indexOf('CircularProgressIndicator()');
    expect(branchAt, greaterThanOrEqualTo(0),
        reason: 'build 必须有 _missingResource 分支');
    expect(spinnerAt, greaterThan(branchAt),
        reason: '_missingResource 分支必须在转圈判据之前（否则仍无限转圈）');
  });

  test('缺失态删除复用既有删除序列 + 二次确认', () {
    expect(source.contains('deleteVideoBook('), isTrue);
    expect(source.contains('reclaimDeletedVideoBookAssets('), isTrue);
    expect(source.contains('compactAfterVideoDeleteBestEffort('), isTrue);
    // 二次确认走既有 video_delete_confirm。
    expect(source.contains('video_delete_confirm'), isTrue);
    // 中性缺失文案 key。
    expect(source.contains('video_resource_missing_message'), isTrue);
  });
}
