import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';

/// injector 失败分类的两侧一致性守卫。
///
/// 背景（真实回归）：`classifyGalHookInjectorFailure` 除了认结构化的
/// `ERR reason=<token>`，还留了一张中文/英文诊断串的兼容表给旧 helper 二进制。
/// PR #1021 把 injector 那条「已存在但不可复用的 hook 会话」拆成了两条——
///
///   * `已存在但不可复用的 hook 会话（驻留 DLL 路径或摘要与本次请求不匹配）` →
///     `kResidentHookMismatch`，**必须重启游戏**（Windows 不卸载已注入 DLL）；
///   * `已存在但暂不可复用的 hook 会话（契约、hooked 或驻留 DLL 身份暂不可确认）` →
///     `kStaleSession`，宿主自己有界重试就会好。
///
/// ——而 Dart 侧那条 `contains('已存在但不可复用的 hook 会话')` 一个字没改：它继续
/// 命中第一条（致命）并把它判成可重试的 staleSession，第二条（真可重试）则一条都
/// 匹配不上退化成 unknown。处置正好反过来，而且没有任何测试会红。
///
/// 所以这条守卫钉的是「表里声称当前 injector 会打出来的串，必须真的还在 injector
/// 源码里逐字存在」——它是让「靠自然语言串识别 native 失败」这个脆判据不至于悄悄
/// 腐烂的唯一机械手段。结构化 token 那条主路同样对齐（native 的
/// `LaunchFailureToken` ⊆ Dart 枚举名）。
void main() {
  late String injectorSource;
  late String failurePolicySource;

  setUpAll(() {
    final File injector =
        File('../native/galgame_hook/injector/injector_main.cpp');
    final File policy =
        File('../native/galgame_hook/include/launch_failure_policy.h');
    expect(injector.existsSync(), isTrue, reason: '${injector.path} 不存在');
    expect(policy.existsSync(), isTrue, reason: '${policy.path} 不存在');
    injectorSource = injector.readAsStringSync();
    failurePolicySource = policy.readAsStringSync();
  });

  test('兼容表里每条非空 sourceLiteral 都必须逐字存在于 injector 源码', () {
    for (final GalHookDiagnosticsMarker entry
        in galHookLegacyDiagnosticsMarkers) {
      if (entry.sourceLiteral.isEmpty) continue;
      expect(
        injectorSource.contains(entry.sourceLiteral),
        isTrue,
        reason: 'injector 已不再产出「${entry.sourceLiteral}」，'
            '而 Dart 仍拿 「${entry.marker}」 把它归类成 ${entry.failure.name}。'
            'injector 改了文案就必须同步改这张表（或把它标成空 sourceLiteral 的'
            '旧二进制兼容项），否则用户会拿到一句与事实相反的处置建议',
      );
    }
  });

  test('兼容表里每条非空 sourceLiteral 都必须真的包含它的 marker', () {
    for (final GalHookDiagnosticsMarker entry
        in galHookLegacyDiagnosticsMarkers) {
      if (entry.sourceLiteral.isEmpty) continue;
      // 例外只有一个：错误码由 `%lu` 在运行期填进去，源码里锚不到具体数值。
      if (entry.marker == 'CreateProcessW failed: 740') {
        expect(entry.sourceLiteral, 'CreateProcessW failed: %lu');
        continue;
      }
      expect(
        entry.sourceLiteral.contains(entry.marker),
        isTrue,
        reason: '「${entry.marker}」不是「${entry.sourceLiteral}」的子串——'
            '锚点与实际匹配串对不上，锚点就证明不了这条 marker 还有产出方',
      );
    }
  });

  test('更具体的 marker 必须排在它的泛化子串之前', () {
    for (int i = 0; i < galHookLegacyDiagnosticsMarkers.length; i++) {
      for (int j = i + 1; j < galHookLegacyDiagnosticsMarkers.length; j++) {
        final GalHookDiagnosticsMarker earlier =
            galHookLegacyDiagnosticsMarkers[i];
        final GalHookDiagnosticsMarker later =
            galHookLegacyDiagnosticsMarkers[j];
        expect(
          later.marker.contains(earlier.marker),
          isFalse,
          reason: '「${earlier.marker}」($i) 是「${later.marker}」($j) 的子串，'
              '排在前面会把后者整条吃掉——这正是 staleSession 与 '
              'residentHookMismatch 被折成一类的形状（两者处置相反）',
        );
      }
    }
  });

  test('表里每条 marker 都能被 classifyGalHookInjectorFailure 判成自己声明的原因', () {
    for (final GalHookDiagnosticsMarker entry
        in galHookLegacyDiagnosticsMarkers) {
      expect(
        classifyGalHookInjectorFailure('[luna] noise\n${entry.marker} tail\n'),
        entry.failure,
        reason: '表被声明了却没被消费，或被前面的条目抢走：${entry.marker}',
      );
    }
  });

  test('拆分后的两条 hook 会话诊断给出相反且正确的处置', () {
    const String fatal =
        '已存在但不可复用的 hook 会话（驻留 DLL 路径或摘要与本次请求不匹配）；'
        '请重启一次游戏以清理旧 DLL。';
    const String transient =
        '已存在但暂不可复用的 hook 会话（契约、hooked 或驻留 DLL 身份暂不可确认）；'
        '将由宿主有界重试。';
    expect(
      classifyGalHookInjectorFailure(fatal),
      GalHookInjectorFailure.residentHookMismatch,
    );
    expect(
      galHookFailureIsRetryable(GalHookInjectorFailure.residentHookMismatch),
      isFalse,
      reason: '驻留 DLL 不同：同一 PID 重试永远不会好，必须让用户重启游戏',
    );
    expect(
      classifyGalHookInjectorFailure(transient),
      GalHookInjectorFailure.staleSession,
    );
    expect(
      galHookFailureIsRetryable(GalHookInjectorFailure.staleSession),
      isTrue,
      reason: '旧映射只是暂不可复用：宿主有界重试就会好，不该惊动用户',
    );
    // 拆分之前 injector 打的是这句，当时它就是可重试的 staleSession；旧 helper 二进制
    // 仍会打它，语义不得被新的具体串顺手改掉。
    expect(
      classifyGalHookInjectorFailure('已存在但不可复用的 hook 会话（契约不匹配或 hooked=0）'),
      GalHookInjectorFailure.staleSession,
    );
  });

  test('native LaunchFailureToken 的每个 token 都能落到 Dart 枚举名上', () {
    final Iterable<RegExpMatch> tokens =
        RegExp(r'return "([A-Za-z]+)";').allMatches(failurePolicySource);
    expect(tokens, isNotEmpty, reason: 'LaunchFailureToken 的 token 表没解析到，'
        '守卫会空转——先确认 launch_failure_policy.h 的写法有没有变');
    final Set<String> dartNames = GalHookInjectorFailure.values
        .map((GalHookInjectorFailure value) => value.name)
        .toSet();
    for (final RegExpMatch match in tokens) {
      final String token = match.group(1)!;
      expect(
        dartNames.contains(token),
        isTrue,
        reason: 'injector 会打 `ERR reason=$token`，但 GalHookInjectorFailure '
            '里没有同名成员——结构化分类会静默退化成 fallback',
      );
    }
  });
}
