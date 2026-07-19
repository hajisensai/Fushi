import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1251 — app 外查词覆盖窗（也含 in-app 弹窗）点音频按钮时，若该词本来就没有
/// 配置音频源（resolveWordAudio 返回 null），旧行为只把 ♪ 瞬间闪成 ✕ 再静默恢复，
/// 读起来像「点了没反应/出错了」，用户不知道是「这个词没有发音」（用户报 1188 族）。
///
/// 修复：无音频源时走独立的 showNoAudioHint —— 在按钮旁弹一个本地化提示
/// 「暂无发音」（window.i18nNoAudioAvailable，宿主经 buildPopupSettingsJs 注入到
/// 两条 render 路径）并把按钮暂时切到 .audio-unavailable 静音态；真正的播放失败仍走
/// showAudioError（透明 ✕）。行为本身需要可见桌面 + 真实热键查一个无音频的词才能
/// 复测（见 docs/agent/integration-testing.md），这里用源码扫描守卫防静默回归。
void main() {
  String read(String p) => File(p).readAsStringSync();

  group('popup.js: no-audio feedback (TODO-1251)', () {
    late String js;
    setUpAll(() {
      js = read('assets/popup/popup.js');
    });

    test('无音频源分支调用 showNoAudioHint 而非静默的 showAudioError', () {
      // createAudioButton 的 !audioUrl 分支必须给出明确提示。
      expect(js.contains('function showNoAudioHint('), isTrue,
          reason: '必须有独立的「暂无发音」提示函数');
      final int start = js.indexOf('function createAudioButton(');
      expect(start, greaterThanOrEqualTo(0));
      final int end = js.indexOf('\nfunction ', start + 1);
      final String body = js.substring(start, end < 0 ? js.length : end);
      expect(body.contains('if (!audioUrl)'), isTrue);
      expect(body.contains('showNoAudioHint(button)'), isTrue,
          reason: '无音频源必须弹「暂无发音」提示（不能只静默闪 ✕）');
    });

    test('showNoAudioHint 用本地化文案 + 生成 .audio-hint 提示 + 切静音态', () {
      final int start = js.indexOf('function showNoAudioHint(');
      final int end = js.indexOf('\nfunction ', start + 1);
      final String body = js.substring(start, end < 0 ? js.length : end);
      expect(body.contains('window.i18nNoAudioAvailable'), isTrue,
          reason: '文案走宿主注入的 i18n（回退中文默认值）');
      expect(body.contains("el('div', { className: 'audio-hint'"), isTrue,
          reason: '必须创建 .audio-hint 提示元素');
      expect(body.contains("classList.add('audio-unavailable')"), isTrue,
          reason: '按钮暂时切到静音态，明示「无发音」');
      // 锚定按钮屏幕坐标（而非视口边缘），保证覆盖窗被裁到卡片 bbox 时也可见。
      expect(body.contains('getBoundingClientRect()'), isTrue,
          reason: '提示锚定到按钮坐标，两种表面都可见');
    });

    test('播放失败仍走透明 showAudioError（只改无音频反馈，不动播放路径）', () {
      final int start = js.indexOf('function createAudioButton(');
      final int end = js.indexOf('\nfunction ', start + 1);
      final String body = js.substring(start, end < 0 ? js.length : end);
      expect(body.contains('playWordAudio(audioUrl)'), isTrue);
      expect(body.contains('showAudioError(button)'), isTrue,
          reason: '有音频但播放失败仍是 showAudioError，不受本次改动影响');
    });
  });

  test('popup.css 定义 .audio-hint 与 .audio-button.audio-unavailable', () {
    final String css = read('assets/popup/popup.css');
    // 断言选择器已定义样式，但对「分组选择器」健壮：BUG-842 起 .audio-hint 与
    // .hoshi-btn-tip 共用同一套视觉，CSS 写成 `.audio-hint,\n.hoshi-btn-tip {`，
    // 旧的裸子串 `.audio-hint {` 不再匹配却仍然生效。这里改为匹配「选择器后紧跟
    // `,`（分组）或 `{`（独立块），允许中间有空白」，既守住样式在位又不锁死写法。
    bool definesSelector(String selector) => RegExp(
          '${RegExp.escape(selector)}\\s*[,{]',
        ).hasMatch(css);
    expect(definesSelector('.audio-hint'), isTrue,
        reason: '.audio-hint 必须作为选择器出现（可与 .hoshi-btn-tip 分组）');
    expect(definesSelector('.audio-hint.visible'), isTrue,
        reason: '.audio-hint.visible 必须定义可见态（可分组）');
    expect(definesSelector('.audio-button.audio-unavailable'), isTrue,
        reason: '.audio-button.audio-unavailable 静音态必须定义');
  });

  test('buildPopupSettingsJs 向两条 render 路径注入 i18nNoAudioAvailable', () {
    final String inj =
        read('lib/src/pages/implementations/popup_settings_injection.dart');
    expect(
      inj.contains(
          'window.i18nNoAudioAvailable = \${jsonEncode(t.popup_no_audio_available)};'),
      isTrue,
      reason: '单一真相源注入，in-app 与 app 外覆盖窗共用同一文案',
    );
  });

  test('i18n key popup_no_audio_available 存在于基准语言文件', () {
    final String base = read('lib/i18n/strings.i18n.json');
    expect(base.contains('"popup_no_audio_available"'), isTrue);
  });
}
