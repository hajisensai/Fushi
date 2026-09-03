import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2092 守卫：attached 状态机里凡是「非终态、需要排障」的状态，`_setStatus`
/// 都必须带 reason。
///
/// 背景：真机上驱动台账只能读到 `attached=<status>/<reason>`。同一个
/// `needsRiskAcceptance` 在该文件里有六个互不相干的来源，`needsCalibration` 有
/// 四个。reason 为 null 时这就是「十二选一」，只能靠读源码逐条排除——实测排了
/// 两轮仍未收敛，直接把 WoH 的适配卡在原地。
void main() {
  const List<String> statusesRequiringReason = <String>[
    'needsRiskAcceptance',
    'needsCalibration',
    'waitingForBodyThread',
    'suspended',
  ];

  late String source;

  setUpAll(() {
    final File file = File('lib/src/lookup/gal_attached_text_controller.dart');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'attached 控制器源文件不在预期路径，守卫失效',
    );
    source = file.readAsStringSync();
  });

  test('排障态的 _setStatus 调用点必须带 reason', () {
    final List<String> offenders = <String>[];
    for (final String status in statusesRequiringReason) {
      // `_setStatus(GalAttachedTextStatus.<status>)` 后面紧跟 `)` 或 `);` 就是
      // 没带任何具名参数的调用。允许换行书写，故先折叠空白。
      // 不带任何具名参数时，调用整体就是 `_setStatus(GalAttachedTextStatus.X)`：
      // 状态名之后直接闭合，中间不会出现逗号。
      final RegExp bare = RegExp(
        r'_setStatus\(\s*GalAttachedTextStatus\.' + status + r'\s*\)',
      );
      final String collapsed = source.replaceAll(RegExp(r'\s+'), ' ');
      if (bare.hasMatch(collapsed)) {
        offenders.add(status);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '以下状态仍有不带 reason 的 _setStatus 调用点，真机上无法定位是哪条分支'
          '（BUG-2092）：$offenders',
    );
  });

  test('reason token 互不重复，一处一因', () {
    final Iterable<RegExpMatch> matches = RegExp(
      r"reason:\s*'([a-z0-9_]+)'",
    ).allMatches(source);
    final List<String> tokens = matches
        .map((RegExpMatch m) => m.group(1)!)
        .toList(growable: false);
    expect(
      tokens.length,
      greaterThanOrEqualTo(12),
      reason: 'BUG-2092 补的 reason token 少了，可能被回退',
    );
    final Set<String> seen = <String>{};
    final Set<String> duplicated = <String>{};
    for (final String token in tokens) {
      if (!seen.add(token)) duplicated.add(token);
    }
    expect(
      duplicated,
      isEmpty,
      reason: '同一个 reason token 被多个分支复用，等于又变回「多选一」：$duplicated',
    );
  });
}
