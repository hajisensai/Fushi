import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-271 文案守卫：画质增强档位说明不得让用户误以为「只能用于动画」。
///
/// 用户报：「为什么画质增强说明是动画，我不能看电视剧吗」。Anime4K / ArtCNN 虽为
/// 动画优化，对真人影视/电视剧也有效（增益较小）；low 档（mpv 内置缩放）更是动画/真人
/// 通用。说明文案必须点明「真人/电视剧也适用」，不能写成 anime 专用，否则真人内容用户
/// 被劝退。本守卫扫 en / zh-CN / zh-HK 三份 i18n，钉死该承诺不回退。
Map<String, dynamic> _load(String file) {
  final File f = File('lib/i18n/$file');
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  group('BUG-271 画质增强说明非「仅动画」', () {
    const List<String> hintKeys = <String>[
      'video_quality_enhancement_hint',
      'video_shader_tier_medium_hint',
      'video_shader_tier_high_hint',
      'video_shader_tier_ultra_hint',
    ];

    test('en：每个档位说明都提及真人 / live-action（不仅动画）', () {
      final Map<String, dynamic> en = _load('strings.i18n.json');
      for (final String key in hintKeys) {
        final String v = (en[key] as String).toLowerCase();
        expect(v.contains('live-action') || v.contains('live action'), isTrue,
            reason: '$key 必须点明真人内容也适用（用户怕只能看动画）');
      }
    });

    test('zh-CN：每个档位说明都提及真人 / 电视剧（不仅动画）', () {
      final Map<String, dynamic> zh = _load('strings_zh-CN.i18n.json');
      for (final String key in hintKeys) {
        final String v = zh[key] as String;
        expect(
            v.contains('真人') || v.contains('电视剧') || v.contains('影视'), isTrue,
            reason: '$key 必须点明真人内容也适用');
      }
    });

    test('zh-HK：每个档位说明都提及真人 / 電視劇（不仅动画）', () {
      final Map<String, dynamic> zh = _load('strings_zh-HK.i18n.json');
      for (final String key in hintKeys) {
        final String v = zh[key] as String;
        expect(
            v.contains('真人') || v.contains('電視劇') || v.contains('影視'), isTrue,
            reason: '$key 必须点明真人内容也适用');
      }
    });

    test('en：说明不得出现「仅 / only ... anime」式排他措辞', () {
      final Map<String, dynamic> en = _load('strings.i18n.json');
      for (final String key in hintKeys) {
        final String v = (en[key] as String).toLowerCase();
        expect(v.contains('only for anime'), isFalse,
            reason: '$key 不得把着色器写成动画专用');
        expect(v.contains('anime only'), isFalse, reason: '$key 不得把着色器写成动画专用');
      }
    });
  });
}
