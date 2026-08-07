import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-041 复核守卫：移动端着色器「文案口径」必须与「底层支持状态」一致，
/// 防再次出现过度承诺（UI 说可用、底层注释说未验证/no-op 的自相矛盾）。
///
/// 复核认定的问题：UI 文案断言「手机上着色器可用」，但底层 apply 路径
/// （video_shader_manager.dart / video_player_controller.dart）注释仍写「移动端
/// no-op / 未验证」。已据 media_kit_video 2.0.1 源码（android_video_controller
/// real.dart:151 `vo ?? 'gpu'` + :199-208 `gpu-context=android`/`opengl-es=yes`）
/// 确证移动端走 vo=gpu 渲染路径、glsl-shaders 生效，故统一口径为「五平台 libmpv 生效，
/// 仅非 libmpv 后端 no-op；移动端效果因机型而异、高档可能掉帧」。
void main() {
  String read(String relPath) => File(relPath).readAsStringSync();

  // 「整类移动端否定」的矛盾措辞：底层一旦再写「移动端 no-op / 移动端静默 /
  // 移动端...未验证」就是回退到被复核退回的过度承诺/自相矛盾，必须红。
  final List<RegExp> contradictoryMobilePhrases = <RegExp>[
    RegExp('移动端静默'),
    RegExp('移动端[^。\n]{0,6}no-op'),
    RegExp('移动端[^。\n]{0,20}未验证'),
    RegExp('仅桌面[^。\n]{0,8}生效'),
  ];

  // 命中前缀含否定词（不/非）的属于「纠正措辞」（如「不是移动端 no-op」「非 libmpv 后端
  // no-op」），是本次修复后的正确表述，不算矛盾，跳过。
  bool isNegatedCorrection(String src, int matchStart) {
    final int from = matchStart - 6 < 0 ? 0 : matchStart - 6;
    final String prefix = src.substring(from, matchStart);
    return prefix.contains('不') || prefix.contains('非');
  }

  const List<String> backingSources = <String>[
    'lib/src/media/video/video_shader_manager.dart',
    'lib/src/media/video/video_player_controller.dart',
    'lib/src/pages/implementations/video_shader_dialog.dart',
  ];

  test('底层着色器路径不得再出现「移动端 no-op / 仅桌面生效」的矛盾措辞', () {
    for (final String path in backingSources) {
      final String src = read(path);
      for (final RegExp re in contradictoryMobilePhrases) {
        for (final Match m in re.allMatches(src)) {
          if (isNegatedCorrection(src, m.start)) continue;
          fail('$path 出现被复核退回的过度承诺/矛盾措辞 "${m.group(0)}"：'
              '移动端 vo=gpu 实际生效，不得再断言整类 no-op / 仅桌面生效');
        }
      }
    }
  });

  test('manager doc 必须留下「移动端生效」的可验证依据出处（media_kit 源码 file:line）', () {
    final String mgr = read('lib/src/media/video/video_shader_manager.dart');
    expect(mgr.contains('android_video_controller'), isTrue,
        reason: '注释须引用 media_kit_video 的 android_video_controller real.dart 作为'
            '「移动端 vo=gpu 着色器生效」的依据出处');
    expect(mgr.contains('vo=gpu') || mgr.contains("vo ?? 'gpu'"), isTrue,
        reason: '注释须点明 media_kit 移动端默认 vo=gpu（着色器在该渲染路径生效）');
    // applyShadersToPlayer 必须显式声明「不是移动端 no-op，只在非 libmpv 后端 no-op」。
    expect(mgr.contains('非 libmpv'), isTrue,
        reason: 'no-op 条件须收敛到「非 libmpv 后端」，而非「移动端」');
  });

  test('移动端性能提示文案存在，且不对效果做无条件「可用」承诺', () {
    final Map<String, dynamic> en =
        jsonDecode(File('lib/i18n/strings.i18n.json').readAsStringSync())
            as Map<String, dynamic>;
    final Map<String, dynamic> zh =
        jsonDecode(File('lib/i18n/strings_zh-CN.i18n.json').readAsStringSync())
            as Map<String, dynamic>;
    final String enHint = en['video_shader_mobile_perf_hint'] as String;
    final String zhHint = zh['video_shader_mobile_perf_hint'] as String;

    expect(enHint, isNotEmpty);
    expect(zhHint, isNotEmpty);

    // 诚实口径：必须带「取决于机型 / 渲染路径」的限定，且保留性能警告。
    expect(zhHint.contains('因机型') || zhHint.contains('渲染路径'), isTrue,
        reason: 'zh 文案须限定「效果因机型 GPU 而异 / 仅标准渲染路径生效」，不得无条件断言可用');
    expect(zhHint.contains('掉帧') || zhHint.contains('发热'), isTrue,
        reason: 'zh 文案须保留性能警告（高档可能掉帧/发热）');
    expect(
        enHint.toLowerCase().contains('vary') ||
            enHint.toLowerCase().contains('render path'),
        isTrue,
        reason:
            'en 文案须限定「effectiveness varies / standard render path」，不得无条件断言可用');

    // 不得出现把着色器说成「一定提升画质 / 保证可用」的绝对措辞。
    expect(zhHint.contains('一定') || zhHint.contains('保证'), isFalse,
        reason: 'zh 文案不得用「一定/保证」做无条件承诺');
  });
}
