import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// vendored `flutter_onnxruntime` 的 delta #8（`freeDimensionOverrides` →
/// ORT `AddFreeDimensionOverrideByName`）必须两半齐全。
///
/// 为什么这条比别的 vendored 守卫更要紧：**只丢 C++ 那一半是完全静默的**。
/// Dart 侧照常把 key 放进 options map，插件不再读它，会话退回动态 shape，而
/// 动态 shape 照单全收静态形状的张量 —— 转录结果逐字正确、日志无异常、
/// `AsrDecodeStats.staticBatches` 照样把这些批记成 static，只是编码器慢 5~7 倍。
/// 没有任何测试会因此变红，除了这一条。
///
/// 反过来只丢 Dart 那一半会编译错（`OnnxSessionFactory.createSession` 传一个不
/// 存在的具名参数），很响，所以那半不需要守卫 —— 但一起钉住成本为零。
Directory _findRepositoryRoot() {
  Directory current = Directory.current.absolute;
  while (true) {
    if (File(
      '${current.path}/third_party/flutter_onnxruntime/PATCHES.md',
    ).existsSync()) {
      return current;
    }
    final Directory parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('找不到 Hibiki 仓库根目录');
    }
    current = parent;
  }
}

void main() {
  final Directory root = _findRepositoryRoot();
  final String vendored = '${root.path}/third_party/flutter_onnxruntime';

  test('Windows 插件真的调了 AddFreeDimensionOverrideByName', () {
    final String src = maskComments(
      File('$vendored/windows/flutter_onnxruntime_plugin.cpp')
          .readAsStringSync(),
    );

    expect(
      src,
      contains('AddFreeDimensionOverrideByName'),
      reason: 'delta #8 的 C++ 半没了：Dart 仍会传 freeDimensionOverrides，插件不再'
          '读它，会话静默退回动态 shape —— 结果正确但编码器慢 5~7 倍，'
          '没有任何别的测试会红',
    );
    expect(
      src,
      contains('freeDimensionOverrides'),
      reason: '插件必须从 options map 里按这个 key 取值，两侧字面量得对上',
    );
  });

  test('Dart 侧 OrtSessionOptions 暴露 freeDimensionOverrides 并放进 toMap', () {
    final String src = maskComments(
      File('$vendored/lib/src/ort_session.dart').readAsStringSync(),
    );

    expect(src, contains('freeDimensionOverrides'));
    // 光有字段不够：不进 toMap 就永远到不了插件那边。
    final int at = src.indexOf('Map<String, dynamic> toMap()');
    expect(at, greaterThan(0), reason: 'toMap 不在了，守卫需更新');
    final int end = src.indexOf('\n  }', at);
    expect(end, greaterThan(at), reason: '找不到 toMap 结尾，守卫需更新');
    expect(
      src.substring(at, end),
      contains("'freeDimensionOverrides'"),
      reason: 'toMap 漏掉这一项 = 参数永远传不到原生侧，与丢掉 C++ 半同样静默',
    );
  });

  test('PATCHES.md 把 delta #8 记进了 re-vendor 清单', () {
    final String md = File('$vendored/PATCHES.md').readAsStringSync();

    expect(
      md,
      contains('AddFreeDimensionOverrideByName'),
      reason: 'delta 表里必须有这一条，否则重新 vendor 时没人知道要补回来',
    );
    // 「照 re-vendor 清单做一遍」必须真能把 8 条 delta 都带回来。
    expect(
      RegExp(r're-apply deltas #1[–-]#(8|9|1[0-9])').hasMatch(md),
      isTrue,
      reason: 're-vendor 清单还停在旧编号 = 照它做就会丢掉后面的 delta',
    );
    expect(
      md,
      isNot(contains('The Dart API under `lib/` is byte-for-byte upstream')),
      reason: 'lib/ 已经有 delta #8 了，这句话是假的',
    );
  });
}
