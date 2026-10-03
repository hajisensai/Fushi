// 游戏内查词 provider 生产白名单的三处镜像守卫（BUG-2718）。
//
// 同一张 (kind, id) 白名单在三个构建单元里各抄一份：
//   - native 注册表 `kLookupGeometryProductionProviderPairs`（hook 侧真源）；
//   - runner `IsProductionProviderPair`（读共享内存 hit 时的校验门）；
//   - Dart `isGalLookupProductionProviderPair`（channel 解析门）。
// runner 不链接 hook 的 ABI 头，所以没法共享常量。漏一处的症状是静默的：hook 照常
// 发布 hit，runner 丢掉，游戏里点了没反应——CMVS（id 16）就这样漏过一次。
// attached_calibrated 是 host 自己排版的，不走 native hit，三处都不该出现在 runner / Dart。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';

const String _ipcHeader = '../native/galgame_hook/include/voice_hook_ipc.h';
const String _registryHeader =
    '../native/galgame_hook/hook/geometry_provider_registry.h';
const String _runnerHeader = 'windows/runner/lookup_hit_validation.h';

const int _attachedCalibratedKind = 4;

Map<String, int> _ipcConstants() {
  final String source = File(_ipcHeader).readAsStringSync();
  final Map<String, int> values = <String, int>{};
  for (final RegExpMatch m in RegExp(
    r'constexpr uint32_t (kLookupGeometryProvider\w+) = (\d+)u;',
  ).allMatches(source)) {
    values[m.group(1)!] = int.parse(m.group(2)!);
  }
  return values;
}

Set<String> _nativePairs() {
  final Map<String, int> constants = _ipcConstants();
  final String source = File(_registryHeader).readAsStringSync();
  final int start = source.indexOf('kLookupGeometryProductionProviderPairs[]');
  expect(start, greaterThan(0), reason: 'native 白名单表改名了，更新守卫');
  final String table = source.substring(start, source.indexOf('};', start));
  final Set<String> pairs = <String>{};
  for (final RegExpMatch m in RegExp(
    r'\{\s*(kLookupGeometryProvider\w+),\s*(kLookupGeometryProviderId\w+)\s*\}',
  ).allMatches(table)) {
    final int? kind = constants[m.group(1)!];
    final int? id = constants[m.group(2)!];
    expect(kind, isNotNull, reason: '未知常量 ${m.group(1)}');
    expect(id, isNotNull, reason: '未知常量 ${m.group(2)}');
    if (kind == _attachedCalibratedKind) continue;
    pairs.add('$kind:$id');
  }
  return pairs;
}

Set<String> _runnerPairs() {
  final String source = File(_runnerHeader).readAsStringSync();
  final int start = source.indexOf('IsProductionProviderPair(');
  expect(start, greaterThan(0), reason: 'runner 白名单函数改名了，更新守卫');
  final String body = source.substring(start, source.indexOf('\n}\n', start));
  final Set<String> pairs = <String>{};
  for (final RegExpMatch c in RegExp(
    r'case (\d+)u:[^\n]*\n\s*return ([^;]+);',
  ).allMatches(body)) {
    for (final RegExpMatch id in RegExp(
      r'id == (\d+)u',
    ).allMatches(c.group(2)!)) {
      pairs.add('${c.group(1)}:${id.group(1)}');
    }
  }
  return pairs;
}

void main() {
  test('runner / Dart 的 provider 白名单与 native 注册表逐对一致', () {
    final Set<String> native = _nativePairs();
    expect(native, isNotEmpty);

    expect(
      _runnerPairs(),
      equals(native),
      reason:
          'runner IsProductionProviderPair 与 native 注册表不一致：'
          '不一致的 provider 的 hit 会在 runner 被静默丢弃（BUG-2718）',
    );

    for (int kind = 0; kind <= 6; kind++) {
      for (int id = 0; id <= 32; id++) {
        expect(
          isGalLookupProductionProviderPair(kind, id),
          native.contains('$kind:$id'),
          reason:
              'Dart isGalLookupProductionProviderPair($kind, $id) '
              '与 native 注册表不一致',
        );
      }
    }
  });

  test('runner 的原生 provider 偏好复用同一白名单，不再手抄第二份', () {
    final String source = File(
      'windows/runner/attached_text_surface_window.cpp',
    ).readAsStringSync();
    final int start = source.indexOf(
      'bool AttachedTextSurfaceWindow::NativeProviderPreferred() const {',
    );
    expect(start, greaterThan(0));
    final String body = source.substring(start, source.indexOf('\n}\n', start));
    expect(body, contains('IsProductionProviderPair('));
    expect(body, isNot(contains('provider_id ==')));
  });
}
