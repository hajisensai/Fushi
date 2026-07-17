import 'package:flutter_test/flutter_test.dart';
import 'video_hibiki_page_source_corpus.dart';

/// video_subtitle_list_panel 组合并守卫（守卫审计合并产物；断言零丢弃）：
/// - 单标题：原 video_subtitle_list_double_title_guard_test.dart 并入；
/// - 打开列表保留控制条：原 video_subtitle_list_keeps_controls_guard_test.dart 并入。
/// （同组 video_subtitle_jump_list_guard_test.dart / video_subtitle_list_push_aside_guard_test.dart
/// 经对抗核查维持独立文件，未并入。）
///
/// ── 单标题（BUG-245 / TODO-280；TODO-314 改 push-aside 后续守）──
/// 根因（BUG-245 原文）：overlay side-panel 系统曾对除 settings 外所有面板套
/// [VideoTranslucentSidePanel]（自带标题栏），而字幕列表的 [VideoSubtitleJumpPanel] 自带
/// 完整 header → 双标题。
///
/// TODO-314：字幕列表已整体改 push-aside（不再走 overlay），由 [_subtitleJumpSidePanel] /
/// [_videoWithSubtitlePanel] 直接渲染 [VideoSubtitleJumpPanel]（自带 header），不再被
/// [VideoTranslucentSidePanel] 套壳。本守卫改为锁 push-aside 面板**直接**渲染
/// VideoSubtitleJumpPanel、不二次套外壳标题栏，延续「单标题」不变量。
///
/// media_kit controls 跑不了 headless，故锁源码结构不变量（与既有 video 守卫范式一致）。
///
/// ── 打开字幕列表保留控制条（BUG-371）──
/// 打开字幕跳转列表（push-aside 侧栏）时，左/右控制按钮应**继续可见可用**，不再被强制
/// 隐藏。字幕列表是 `Row[Expanded(video), 面板列]`（TODO-314），把画面挤窄到左侧、不遮挡
/// 叠在画面上的控制层/rail，故打开它时不应压制控制条。
///
/// 用户：「字幕列表只是侧边栏，左边的按钮应该还可以换出（仍可用）」。
///
/// 三处抑制门控不含 _subtitleListVisible 的反向断言在
/// video_side_panel_suppress_controls_guard_test.dart；本文件补 `_toggleSubtitleJumpList`
/// 打开分支不再主动收起控制条（`_markControlsVisible(false)`）的不变量。
void main() {
  late String src;
  setUpAll(() {
    src = readVideoHibikiSource();
  });

  group('单标题（BUG-245 / TODO-280 / TODO-314）', () {
    /// 截取 push-aside 字幕面板列构造器 [_subtitleJumpSidePanel] 方法体。
    ///
    /// TODO-590 batch5：`_subtitleJumpSidePanel` 已抽到 `video_hibiki/subtitle.part.dart`
    /// 并成为合并语料里的最后一个方法（其后只剩 extension 闭合 `}`），不再有「下一个顶层
    /// 方法签名」可作结束端点，故改用花括号配对截取方法体。
    String pushAsidePanelBody() {
      final int start = src.indexOf('Widget _subtitleJumpSidePanel(');
      expect(start, greaterThanOrEqualTo(0),
          reason: '需有 push-aside 字幕面板列 _subtitleJumpSidePanel');
      final int open = src.indexOf('{', start);
      expect(open, greaterThan(start), reason: '_subtitleJumpSidePanel 应有方法体');
      int depth = 0;
      int end = src.length;
      for (int i = open; i < src.length; i++) {
        if (src[i] == '{') {
          depth++;
        } else if (src[i] == '}') {
          depth--;
          if (depth == 0) {
            end = i + 1;
            break;
          }
        }
      }
      expect(end, greaterThan(start), reason: '_subtitleJumpSidePanel 应正常闭合');
      return src.substring(start, end);
    }

    test('push-aside 字幕面板直接渲染 VideoSubtitleJumpPanel（自带 header，不双标题）', () {
      final String body = pushAsidePanelBody();
      expect(body.contains('VideoSubtitleJumpPanel('), isTrue,
          reason: 'push-aside 面板应直接渲染 VideoSubtitleJumpPanel（自带 header + 关闭）');
      expect(body.contains('VideoTranslucentSidePanel('), isFalse,
          reason: '字幕面板不应再被 VideoTranslucentSidePanel 套一层标题栏（否则双标题，BUG-245）');
    });

    test('字幕列表已无 overlay 路径（不再走 _buildVideoSidePanelContent 的 subtitleList 分支）',
        () {
      // overlay 内容构造器不应再对 subtitleList 单独分支（该 kind 已删）。
      // TODO-590 batch10：_buildVideoSidePanelContent 已抽到 video_hibiki/side_panel.part.dart
      // 并是该 part 末方法；旧的 _buildAudioTracksSidePanel 终点失效（它在 audio_track.part，
      // 排在合并语料里 side_panel.part 之前，即在搬出后的 content 之前）。改用 part 顶格
      // extension 闭合 `\n}` 作终点（content 体内无顶格 `}`）。
      final int start = src.indexOf('Widget _buildVideoSidePanelContent(');
      expect(start, greaterThanOrEqualTo(0));
      final int end = src.indexOf('\n}', start);
      expect(end, greaterThan(start));
      final String contentBody = src.substring(start, end);
      expect(
        contentBody.contains('_VideoSidePanelKind.subtitleList'),
        isFalse,
        reason: 'overlay 内容构造器不应再引用 subtitleList（已改 push-aside）',
      );
    });
  });

  group('打开字幕列表保留控制条（BUG-371）', () {
    String methodBody(String signature, String endMarker) {
      final int start = src.indexOf(signature);
      expect(start, greaterThanOrEqualTo(0), reason: '需有 $signature');
      final int end = src.indexOf(endMarker, start + signature.length);
      expect(end, greaterThan(start),
          reason: '需有 $endMarker 作为 $signature 的段终点');
      return src.substring(start, end);
    }

    test('_toggleSubtitleJumpList 打开分支不再 _markControlsVisible(false)', () {
      final String body = methodBody(
        'void _toggleSubtitleJumpList() {',
        'void _closeSubtitleJumpList() {',
      );
      expect(body.contains('_subtitleListVisible.value = true;'), isTrue,
          reason: '打开分支仍应置 _subtitleListVisible = true（push-aside 入口）');
      expect(body.contains('_markControlsVisible(false);'), isFalse,
          reason: 'BUG-371：打开字幕列表不应主动收起控制条——它是 push-aside 不遮控制条，'
              '左/右按钮应继续可见可用');
    });
  });
}
