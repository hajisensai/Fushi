import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';

/// galgame 纯人声配对纯函数 [pickPairedVoiceOgg] 单测（真机验证的配对规律固化）：文本行
/// 时间戳对应的语音优先取同 tick 资源；没有时再取 [T-330, T-130] 内、离期望偏移
/// T-220 最近、且非 BGM/SE 的 OGG。
void main() {
  group('pickPairedVoiceOgg', () {
    test('Anemoi 新资源导出同 tick 时优先于旧的 T-220 候选', () {
      final List<String> files = <String>[
        '636939592_old_style.ogg',
        '636939812_z5044.ovk_125778.ogg',
      ];
      expect(
        pickPairedVoiceOgg(oggFileNames: files, textTsMs: 636939812),
        '636939812_z5044.ovk_125778.ogg',
      );
    });

    test('挑窗口内、离期望偏移(约 T-220)最近的语音', () {
      // 文本 T=10000 → 窗口 [9670, 9870]，期望中心 9780。
      final List<String> files = <String>[
        '9780_yui001.ogg', // 命中中心
        '9600_yui000.ogg', // 太早（窗口外）
        '9950_yui002.ogg', // 太晚（窗口外）
      ];
      expect(
        pickPairedVoiceOgg(oggFileNames: files, textTsMs: 10000),
        '9780_yui001.ogg',
      );
    });

    test('窗口内也排除 BGM/SE（按 basename 前缀）', () {
      final List<String> files = <String>[
        '9790_bgm_theme.ogg', // 窗口内但 BGM，排除
        '9770_se_click.ogg', // 窗口内但 SE，排除
        '9760_osy012.ogg', // 角色语音，选它
      ];
      expect(
        pickPairedVoiceOgg(oggFileNames: files, textTsMs: 10000),
        '9760_osy012.ogg',
      );
    });

    test('窗口内无候选时返回 null', () {
      final List<String> files = <String>[
        '9000_yui.ogg',
        '9990_yui.ogg',
      ];
      expect(pickPairedVoiceOgg(oggFileNames: files, textTsMs: 10000), isNull);
    });

    test('忽略非法文件名（无数字 tick 前缀）', () {
      final List<String> files = <String>[
        'voice.ogg', // 无下划线
        '_yui.ogg', // 下划线在首位
        'abc_yui.ogg', // tick 非数字
        '9780_yui.ogg', // 合法
      ];
      expect(
        pickPairedVoiceOgg(oggFileNames: files, textTsMs: 10000),
        '9780_yui.ogg',
      );
    });

    test('多个窗口内候选时取离期望偏移最近者', () {
      final List<String> files = <String>[
        '9700_a.ogg', // |9700-9780|=80
        '9780_b.ogg', // |9780-9780|=0  ← 最近
        '9850_c.ogg', // |9850-9780|=70
      ];
      expect(
        pickPairedVoiceOgg(oggFileNames: files, textTsMs: 10000),
        '9780_b.ogg',
      );
    });
  });

  group('pickPairedUnityVoiceWav', () {
    test('取播放事件时间戳离文本最近的资源 WAV', () {
      final List<String> files = <String>[
        '9900_0205Adv01_Noah001.wav',
        '10040_0205Adv01_Noah002.wav',
        '10700_0205Adv01_Noah003.wav',
      ];
      expect(
        pickPairedUnityVoiceWav(wavFileNames: files, textTsMs: 10000),
        '10040_0205Adv01_Noah002.wav',
      );
    });

    test('窗口外资源与非语音名不会参与', () {
      final List<String> files = <String>[
        '8000_0205Adv01_Noah001.wav',
        '9990_bgm_theme.wav',
      ];
      expect(
        pickPairedUnityVoiceWav(wavFileNames: files, textTsMs: 10000),
        isNull,
      );
    });
  });

  group('pickPairedGameResource', () {
    test('有时间戳但精确窗口未命中时绝不冒用会话最新语音', () {
      expect(
        pickPairedGameResource(
          oggFileNames: const <String>['9000_old_line.ogg'],
          wavFileNames: const <String>[],
          textTsMs: 10000,
          latestSessionVoiceName: '11000_other_line.ogg',
        ),
        isNull,
      );
    });

    test('无文本时间戳时允许 Siglus 晚附着使用本会话最新语音', () {
      expect(
        pickPairedGameResource(
          oggFileNames: const <String>[],
          wavFileNames: const <String>[],
          textTsMs: 0,
          latestSessionVoiceName: '11000_current_session.ogg',
        ),
        '11000_current_session.ogg',
      );
    });

    test('有时间戳时精确 Unity 资源优先于会话最新语音', () {
      expect(
        pickPairedGameResource(
          oggFileNames: const <String>['9780_siglus.ogg'],
          wavFileNames: const <String>['10020_unity.wav'],
          textTsMs: 10000,
          latestSessionVoiceName: '11000_other_line.ogg',
        ),
        '10020_unity.wav',
      );
    });
  });
}
