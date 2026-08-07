import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1069 / TODO-1070 / TODO-1072：悬浮字幕设置三修的源码 + i18n 守卫。
///
/// 这三处 bug 的根因都在「onChanged 少调一步」或「文案含糊」，回归极易再犯（复制别的
/// onChanged 时漏 apply、或改文案时手滑）。用确定性源码 / i18n 守卫钉死，比起需要拉起
/// 原生悬浮窗后端的行为测试更可落地、更快、更稳（对齐仓库既有
/// `floating_lyric_bg_opacity_test.dart` 的 source-guard 风格）。
void main() {
  final String schema = File('lib/src/settings/settings_schema_listening.dart')
      .readAsStringSync();
  final String appModel =
      File('lib/src/models/app_model.dart').readAsStringSync();

  group('TODO-1069：悬浮字幕字号改值即时推给原生窗', () {
    test('字号 stepper 的 onChanged 在写 pref 后调 applyFloatingLyricStyle', () {
      // 漏这一步时字号只写 pref，原生窗不刷新（得等改透明度才顺带推过去）。与透明度
      // 三项对齐：setFloatingLyricFontSize(...) 紧跟 applyFloatingLyricStyle()。
      expect(
        RegExp(
          r'setFloatingLyricFontSize\(value\);[\s\S]*?'
          r'applyFloatingLyricStyle\(\)',
        ).hasMatch(schema),
        isTrue,
        reason: '悬浮字幕字号 onChanged 必须调 applyFloatingLyricStyle() 即时重推样式。',
      );
    });
  });

  group('TODO-1069 / TODO-1070：总开关走语义意图入口（置位 + 拉/隐窗 + 写意图 pref）', () {
    test(
        '设置页总开关 onChanged 委托 setFloatingLyricEnabled，不再裸写 setShowFloatingLyric',
        () {
      // 定位到 floating_lyric（非 font_size）那条 SwitchItem 的 onChanged 块。
      final int idx = schema.indexOf("id: 'listening.floating_lyric'");
      expect(idx, greaterThanOrEqualTo(0));
      final int fontIdx =
          schema.indexOf("id: 'listening.floating_lyric_font_size'", idx);
      expect(fontIdx, greaterThan(idx));
      final String switchBlock = schema.substring(idx, fontIdx);

      expect(
        switchBlock.contains('setFloatingLyricEnabled(value)'),
        isTrue,
        reason: '总开关必须走 setFloatingLyricEnabled 语义入口（置位 + 原子拉/隐原生窗）。',
      );
      expect(
        switchBlock.contains('setShowFloatingLyric('),
        isFalse,
        reason: '总开关不得裸写 setShowFloatingLyric 旁路（不显隐窗 → 与书内翻转反相、不即时）。',
      );
    });

    test(
        'AppModel.setFloatingLyricEnabled 存在且是置位语义（非翻转），有会话时经 toggleFloatingLyric 显隐',
        () {
      final int idx = appModel.indexOf(
        'Future<bool> setFloatingLyricEnabled(bool value) async {',
      );
      expect(idx, greaterThanOrEqualTo(0),
          reason: '语义意图入口 setFloatingLyricEnabled 必须存在。');
      // 方法体（到下一个顶层方法之前，取一段足够长的窗口）。
      final String body = appModel.substring(idx, idx + 1400);

      // 置位而非翻转：把 value 写进 pref（不是 !currentlyOn）。
      expect(
        body.contains('await setShowFloatingLyric(value);'),
        isTrue,
        reason: '意图 pref 必须被置为 value（置位语义），不是翻转。',
      );
      // 有会话时以 isActive 门控，经 toggleFloatingLyric 原子拉/隐原生窗。
      expect(body.contains('audiobookSession.isActive'), isTrue);
      expect(body.contains('audiobookSession.toggleFloatingLyric'), isTrue);
      // 拉窗失败（缺 overlay 权限）不写 pref、返回 false。
      expect(
        RegExp(r'if \(!ok\) return false;').hasMatch(body),
        isTrue,
        reason: '拉起原生窗失败时必须提前返回 false 且不写 pref（never-break 权限门控）。',
      );
    });

    test(
        '退书 stop() 隐窗时不改意图 pref（_stopBackgroundSurfaces 不写 setShowFloatingLyric）',
        () {
      final String session = File(
        'lib/src/media/audiobook/audiobook_session.dart',
      ).readAsStringSync();
      final int idx = session.indexOf('Future<void> _stopBackgroundSurfaces()');
      expect(idx, greaterThanOrEqualTo(0));
      final int end = session.indexOf('\n  }', idx);
      final String body = session.substring(idx, end);
      // 退出即停只隐窗（hide），绝不触碰意图 pref——否则退书会把用户意图清成 false，
      // 下次进书悬浮窗就不再自动拉起（TODO-1070 反相根因之一）。
      expect(body.contains('FloatingLyricChannel.hide()'), isTrue);
      expect(
        body.contains('setShowFloatingLyric') ||
            body.contains('onFloatingLyricClosePersist'),
        isFalse,
        reason: '退书 stop 隐窗不得改意图 pref（保持用户意图，供进书自动拉起）。',
      );
    });
  });

  group('TODO-1072：悬浮字幕描述文案更明确', () {
    test('floating_lyric_hint 的 en/zh 值已更新为「悬浮当前播放字幕句」的明确表述', () {
      final Map<String, String> want = <String, String>{
        'lib/i18n/strings.i18n.json':
            'Float the currently playing subtitle line on top of other apps.',
        'lib/i18n/strings_zh-CN.i18n.json': '将当前播放的字幕句悬浮显示在其他应用之上。',
      };
      want.forEach((String path, String value) {
        final String src = File(path).readAsStringSync();
        expect(
          src.contains('"floating_lyric_hint": "$value"'),
          isTrue,
          reason: '$path 的 floating_lyric_hint 必须是更新后的明确文案。',
        );
      });
      // 生成文件同步（跑过 dart run slang）。
      final String gen = File('lib/i18n/strings.g.dart').readAsStringSync();
      expect(gen.contains(want['lib/i18n/strings.i18n.json']!), isTrue);
      expect(gen.contains(want['lib/i18n/strings_zh-CN.i18n.json']!), isTrue);
    });

    test('旧含糊文案已不复存在（防回退）', () {
      for (final String path in <String>[
        'lib/i18n/strings.i18n.json',
        'lib/i18n/strings_zh-CN.i18n.json',
      ]) {
        final String src = File(path).readAsStringSync();
        expect(src.contains('Show current sentence over other apps.'), isFalse);
        expect(src.contains('在其他应用上方显示当前句子。'), isFalse);
      }
    });
  });
}
