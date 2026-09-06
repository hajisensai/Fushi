import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

/// 守卫：字幕列表行内复制的**单一契约** —— `VideoSubtitleJumpPanel.onCopyCue`
/// 返回「是否真的写了剪贴板」，面板据此决定要不要把该行按钮切成 ✓。
///
/// 为什么要这条守卫（两个各自独立的理由）：
///
/// ① **网页视频页那条腿没有任何行为覆盖**。`web_video_fushi_page.dart` 的
///    `_copyCue` 要立起 widget 测试得先有 WebView + AppModel + Riverpod 容器，
///    代价远超收益；实测把它整个变成 no-op，全仓 8000+ 条测试无一察觉。源码扫描
///    是这条腿能落地的最强一层。
///
/// ② **判据曾经有三份**：面板按钮里一份 `cue.text.trim().isNotEmpty`、原生页
///    `_copyCueText` 一份、网页页 `_copyCue` 一份。三份判据迟早漂开（面板认为
///    复制成功、实现方其实什么都没写，✓ 就是在骗人）。收敛后判据只归实现方，
///    面板只读返回值——这条守卫钉住的就是「面板不许自己重算」。
///
/// 「✓ 在播放头离开该行时提前消失」（BUG-2093）的行为面由
/// `video_subtitle_jump_panel_test.dart` 的 widget 用例覆盖，两层不重复。
///
/// flutter test 的 cwd 是 fushi 包根。
void main() {
  final File panel = File('lib/src/media/video/video_subtitle_jump_panel.dart');
  final File nativePart = File(
    'lib/src/pages/implementations/video_fushi/lookup_favorite.part.dart',
  );
  final File webPage = File(
    'lib/src/pages/implementations/web_video_fushi_page.dart',
  );
  final File nativeWiring = File(
    'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
  );

  late String panelSrc;
  late String nativePartSrc;
  late String webSrc;
  late String nativeWiringSrc;

  setUpAll(() {
    for (final File f in <File>[panel, nativePart, webPage, nativeWiring]) {
      expect(f.existsSync(), isTrue, reason: '找不到 ${f.path}');
    }
    panelSrc = panel.readAsStringSync();
    nativePartSrc = nativePart.readAsStringSync();
    webSrc = webPage.readAsStringSync();
    nativeWiringSrc = nativeWiring.readAsStringSync();
  });

  group('onCopyCue 契约：返回值即「写了剪贴板没有」', () {
    test('面板声明的回调类型是 bool Function(AudioCue)', () {
      expect(
        maskComments(
          panelSrc,
        ).contains('final bool Function(AudioCue cue) onCopyCue;'),
        isTrue,
        reason: '回调必须交出成功与否，否则面板只能自己猜（判据第二份）',
      );
    });

    test('复制按钮：只在 onCopyCue 报成功时记账，且不自己重算判据', () {
      final String actions = methodBody(panelSrc, 'Widget _buildRowActions(');
      expect(
        containsCodeLine(
          actions,
          'if (widget.onCopyCue(cue)) '
          '_markCueCopied(rawIndex);',
        ),
        isTrue,
        reason: '成功与否由实现方说了算',
      );
      expect(
        containsCodeLine(actions, 'cue.text.trim().isNotEmpty'),
        isFalse,
        reason: '面板重算判据 = 判据第二份，迟早与实现方漂开',
      );
      expect(
        containsIdentifierCall(actions, 'CopyFeedback'),
        isFalse,
        reason: 'BUG-2093：行内 State 会被列表的 key 翻转清零，状态必须归面板',
      );
      expect(
        containsCodeLine(actions, 'rawIndex == _copiedRawIndex'),
        isTrue,
        reason: '✓ 按面板持有的 rawIndex 渲染',
      );
    });

    test('面板持有回落定时器，并随 dispose 取消', () {
      final String mark = methodBody(panelSrc, 'void _markCueCopied(');
      expect(containsIdentifierCall(mark, 'Timer'), isTrue);
      expect(containsIdentifier(mark, 'kCopyFeedbackDuration'), isTrue);
      expect(
        containsCodeLine(mark, '_copyFeedbackTimer?.cancel();'),
        isTrue,
        reason: '维持期内再复制要重新计时，不能被旧定时器提前打回',
      );
      final String dispose = methodBody(panelSrc, 'void dispose() {');
      expect(
        containsCodeLine(dispose, '_copyFeedbackTimer?.cancel();'),
        isTrue,
        reason: '不取消就会在卸载后 setState 打到已 dispose 的 State',
      );
    });

    test('原生视频页 _copyCueText：空句 false、写剪贴板后 true', () {
      final String body = methodBody(
        nativePartSrc,
        'bool _copyCueText(AudioCue cue) {',
      );
      expect(containsCodeLine(body, 'if (text.isEmpty) return false;'), isTrue);
      expect(containsIdentifierCall(body, 'Clipboard.setData'), isTrue);
      expect(containsCodeLine(body, 'return true;'), isTrue);
      expect(
        containsCodeLine(nativeWiringSrc, 'onCopyCue: _copyCueText,'),
        isTrue,
        reason: '面板接的就是它',
      );
    });

    test('网页视频页 _copyCue：空句 false、经 AppModel 写剪贴板后 true', () {
      // 这条是网页页那条腿**唯一**的自动化覆盖：把 _copyCue 变 no-op 立刻红。
      final String body = methodBody(webSrc, 'bool _copyCue(AudioCue cue) {');
      expect(containsCodeLine(body, 'if (text.isEmpty) return false;'), isTrue);
      expect(
        containsIdentifierCall(body, '_appModel.copyToClipboard'),
        isTrue,
        reason: '必须走 AppModel（按平台决定要不要弹「已复制」toast）；'
            '网页视频页没有原生页那套 OSD，裸 Clipboard.setData 等于零反馈',
      );
      expect(
        containsIdentifierCall(body, 'Clipboard.setData'),
        isFalse,
        reason: '裸写剪贴板会绕过平台感知的 toast',
      );
      expect(containsCodeLine(body, 'return true;'), isTrue);
      expect(
        containsCodeLine(webSrc, 'onCopyCue: _copyCue,'),
        isTrue,
        reason: '面板接的就是它',
      );
    });
  });
}
