import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：视频查词浮层顶栏的「当前字幕句」动作行。
///
/// 用户诉求：在视频查词浮窗里就能重播/跳转/复制当前那句，不必关掉浮窗再去右侧字幕
/// 列表把那一行找回来。顶栏原先只有一个收藏 ★。
///
/// 这是**接线守卫**：四个按钮的存在、各自接到哪个 handler、handler 又落到播放器的
/// 哪个 API。真正的时序逻辑（播到句尾一次性暂停）由
/// `test/media/video/video_player_replay_cue_test.dart` 行为测试覆盖，两层不重复。
///
/// 顶栏是纯 Flutter widget（`DictionaryPopupLayer._buildTopBar` 的 headerWidget 注入点），
/// 但要立起来需要整个视频页 State + media_kit + DB，widget 测试代价远超收益；接线层
/// 的回归（按钮被误删、handler 接错）源码扫描即可咬死。
void main() {
  final File page =
      File('lib/src/pages/implementations/video_hibiki_page.dart');
  final File part = File(
    'lib/src/pages/implementations/video_hibiki/lookup_favorite.part.dart',
  );

  late String pageSrc;
  late String partSrc;

  setUpAll(() {
    expect(page.existsSync(), isTrue);
    expect(part.existsSync(), isTrue);
    pageSrc = page.readAsStringSync();
    partSrc = part.readAsStringSync();
  });

  /// 取 [src] 中 [startSig] 到 [endSig] 之间的片段。从**方法签名**起截，把方法上方的
  /// doc 注释排除在外——否则注释里提到的符号会把断言喂绿（假绿）。
  String region(String src, String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, isNonNegative, reason: 'missing region start: $startSig');
    final int end = src.indexOf(endSig, start);
    expect(end, isNonNegative, reason: 'missing region end: $endSig');
    return src.substring(start, end);
  }

  group('查词浮层顶栏：当前字幕句动作行', () {
    late String header;

    setUpAll(() {
      header = region(
        pageSrc,
        'Widget? buildPopupHeaderFor(int index) {',
        '/// 关闭查词浮层栈中第',
      );
    });

    test('四个动作按钮都在（重播 / 跳转 / 复制 / 收藏）', () {
      for (final String key in <String>[
        'video_popup_replay_cue_button',
        'video_popup_jump_to_cue_button',
        'video_popup_copy_sentence_button',
        'video_favorite_sentence_button',
      ]) {
        expect(
          header.contains("Key('$key')"),
          isTrue,
          reason: '顶栏缺少动作按钮 $key',
        );
      }
    });

    test('每个按钮接到各自的 handler', () {
      for (final String handler in <String>[
        '_replayLookupCue',
        '_jumpToLookupCue',
        '_copyLookupSentence',
        '_toggleFavoriteSentenceForVideo',
      ]) {
        expect(
          header.contains('onTap: $handler'),
          isTrue,
          reason: '顶栏按钮未接到 $handler',
        );
      }
    });

    test('无锚定 cue 时重播/跳转置灰，而不是留着点了没反应', () {
      // 无字幕轨 / gap 中查词时没有可重播可跳转的句子。复制不受此限（回落整句文本）。
      expect(
        header.contains('final bool hasCue ='),
        isTrue,
        reason: '缺少「是否有锚定 cue」的判定',
      );
      expect(
        'enabled: hasCue'.allMatches(header).length,
        2,
        reason: '重播与跳转两个按钮都必须按 hasCue 置灰',
      );
    });
  });

  group('顶栏 handler 落到播放器 API', () {
    test('_replayLookupCue 走 replayCue（一次性句尾暂停），不是裸 seek', () {
      final String body = region(
        partSrc,
        'Future<void> _replayLookupCue() async {',
        '\n  }',
      );
      expect(
        body.contains('controller.replayCue('),
        isTrue,
        reason: '重播必须走 replayCue —— 句尾暂停的时序在播放器层',
      );
    });

    test('_jumpToLookupCue 走 skipToCue（与字幕列表行同一入口）', () {
      final String body = region(
        partSrc,
        'Future<void> _jumpToLookupCue() async {',
        '\n  }',
      );
      expect(
        body.contains('controller.skipToCue('),
        isTrue,
        reason: '跳转必须复用 skipToCue，保持前导余量与 cue-snap 一致',
      );
    });

    test('_copyLookupSentence 优先复制锚定 cue 文本，无 cue 时回落整句', () {
      final String body = region(
        partSrc,
        'void _copyLookupSentence() {',
        '\n  }',
      );
      expect(body.contains('Clipboard.setData('), isTrue);
      expect(
        body.contains('_lastLookupSentence'),
        isTrue,
        reason: '无 cue（无字幕轨 / gap 查词）时必须回落，按钮不能变哑',
      );
    });

    test('重播不改写 _pausedForLookup（关浮层恢复播放的依据，BUG-072）', () {
      final String body = region(
        partSrc,
        'Future<void> _replayLookupCue() async {',
        '\n  }',
      );
      expect(
        body.contains('_pausedForLookup'),
        isFalse,
        reason: '浮层内试听不得篡改「查词前是否在播」的记录',
      );
    });
  });
}
