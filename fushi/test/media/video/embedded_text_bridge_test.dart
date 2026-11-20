// 本地视频内封文本轨「先播后补」（PR #3679 的后续，反馈 ZTDA2WQJj4）：整轨抽取在慢盘上
// 要一分钟以上，期间先借播放器解码这条轨即时出字（可点 overlay），抽完换成完整 cue
// 列表。这里用假 PlatformPlayer（不碰 libmpv）钉住控制器侧的换装契约：
//  - 抽取期间回流的句子即时成为当前句；
//  - 换成完整列表那一下监听者看不到「当前句为空」（不闪）、同一句不出现两份、当前句不丢；
//  - 换装后播放器停止解码字幕轨（关 sid）；
//  - 期间换过字幕源（用户另选 / 关字幕）的桥作废，迟到的完整列表不覆盖新选择。
import 'dart:async';

import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:media_kit/media_kit.dart';
import 'package:test/test.dart';

/// 只用 [PlatformPlayer] 自带的 state / 流；`sub-*` 属性与 setProperty 走 dynamic 分派
/// （控制器经 `player.platform` 动态调用 libmpv 补丁方法）。
class _FakeMpv extends PlatformPlayer {
  _FakeMpv() : super(configuration: const PlayerConfiguration()) {
    state = state.copyWith(
      tracks: const Tracks(
        subtitle: <SubtitleTrack>[
          SubtitleTrack('auto', null, null),
          SubtitleTrack('no', null, null),
          SubtitleTrack('1', 'jpn', 'jpn'),
          SubtitleTrack('2', 'eng', 'eng'),
        ],
      ),
    );
  }

  final Map<String, String> props = <String, String>{};
  final List<String> selectedSubtitleIds = <String>[];

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    selectedSubtitleIds.add(track.id);
    state = state.copyWith(track: state.track.copyWith(subtitle: track));
  }

  Future<void> setProperty(String property, String value) async {
    props[property] = value;
  }

  /// 批量下发（`setMpvPropertiesInOrder`）走的带结果码写法；0 = 接受。
  Future<int> setPropertyWithResult(String property, String value) async {
    props[property] = value;
    return 0;
  }

  Future<String> getPropertyAsync(
    String property, {
    bool waitForInitialization = true,
  }) async => props[property] ?? '';

  void setPosition(int ms) {
    state = state.copyWith(position: Duration(milliseconds: ms));
  }

  /// libmpv 换句：`sub-text` / `sub-start` / `sub-end` 先就位，再经 subtitle 流上报。
  void showLine(String text, double startS, double endS) {
    props['sub-text'] = text;
    props['sub-start'] = startS.toStringAsFixed(6);
    props['sub-end'] = endS.toStringAsFixed(6);
    final List<String> slots = <String>[text, ''];
    state = state.copyWith(subtitle: slots);
    // ignore: invalid_use_of_protected_member
    subtitleController.add(slots);
  }
}

AudioCue _cue(String text, int startMs, int endMs) => AudioCue()
  ..bookKey = ''
  ..chapterHref = ''
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

/// 让控制器把异步的 `_onPlayerDecodedText`（几次 getPropertyAsync）跑完。
Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _FakeMpv mpv;
  late VideoPlayerController controller;

  setUp(() {
    mpv = _FakeMpv();
    controller = VideoPlayerController()
      ..debugAttachPlayerForTesting(Player(platformPlayer: mpv));
  });

  test('抽取期间播放器解码的句子即时上屏；换成完整列表不闪、不重复、当前句不丢', () async {
    mpv.setPosition(1500);
    mpv.showLine('一句目', 1.0, 3.0);
    final Object? token = await controller.beginEmbeddedTextBridge(0);
    expect(token, isNotNull);
    expect(
      mpv.selectedSubtitleIds.last,
      '1',
      reason: '第 0 条内嵌轨 = libmpv 第一条真实轨',
    );
    expect(controller.isPlayerDecodedTextSubtitleActive, isTrue);
    expect(
      mpv.props['sub-visibility'],
      'no',
      reason: '只解码不画：字幕只由可点 overlay 画，不能和 libmpv 自绘叠两层',
    );
    await _settle();
    expect(controller.currentCue?.text, '一句目');

    mpv.setPosition(3500);
    mpv.showLine('二句目', 3.0, 5.0);
    await _settle();
    expect(controller.cues.map((AudioCue c) => c.text), <String>['一句目', '二句目']);
    expect(controller.currentCue?.text, '二句目');

    final List<String?> seen = <String?>[];
    controller.addListener(() => seen.add(controller.currentCue?.text));
    final bool applied = controller.completeEmbeddedTextBridge(
      token!,
      <AudioCue>[
        _cue('一句目', 1000, 3000),
        _cue('二句目', 3000, 5000),
        _cue('三句目', 5000, 7000),
      ],
    );

    expect(applied, isTrue);
    expect(seen, isNotEmpty);
    expect(
      seen,
      everyElement('二句目'),
      reason: '换装那一下监听者（overlay）不能看到空的当前句：$seen',
    );
    expect(controller.cues.map((AudioCue c) => c.text), <String>[
      '一句目',
      '二句目',
      '三句目',
    ], reason: '完整列表整份替换回流列表，同一句不能出现两份');
    expect(controller.isPlayerDecodedTextSubtitleActive, isFalse);
    await _settle();
    expect(mpv.selectedSubtitleIds.last, 'no', reason: '换上完整列表后播放器不必再解码字幕轨');
    expect(controller.isEmbeddedTextBridgeLive(token), isFalse);
  });

  test('桥期间换过字幕源：迟到的完整列表作废，不覆盖新选择', () async {
    mpv.setPosition(1500);
    mpv.showLine('一句目', 1.0, 3.0);
    final Object? token = await controller.beginEmbeddedTextBridge(0);
    expect(token, isNotNull);
    await _settle();

    // 用户另选了一份外挂字幕（或关字幕：setCues(const [])）。
    controller.setCues(<AudioCue>[_cue('外挂', 1000, 3000)]);
    expect(controller.isEmbeddedTextBridgeLive(token!), isFalse);

    final bool applied = controller.completeEmbeddedTextBridge(
      token,
      <AudioCue>[_cue('一句目', 1000, 3000)],
    );
    expect(applied, isFalse);
    expect(controller.cues.map((AudioCue c) => c.text), <String>['外挂']);
  });

  test('另一座桥替换了旧桥：旧令牌失效，新令牌可换装', () async {
    mpv.setPosition(1500);
    final Object? first = await controller.beginEmbeddedTextBridge(0);
    final Object? second = await controller.beginEmbeddedTextBridge(1);
    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(controller.isEmbeddedTextBridgeLive(first!), isFalse);
    expect(controller.isEmbeddedTextBridgeLive(second!), isTrue);
    expect(mpv.selectedSubtitleIds.last, '2');
    expect(
      controller.completeEmbeddedTextBridge(first, <AudioCue>[
        _cue('x', 1000, 2000),
      ]),
      isFalse,
    );
    expect(
      controller.completeEmbeddedTextBridge(second, <AudioCue>[
        _cue('English', 1000, 2000),
      ]),
      isTrue,
    );
    expect(controller.currentCue?.text, 'English');
  });

  test('序号越界 / 没有播放器：不装桥（调用方照旧等完整列表）', () async {
    expect(await controller.beginEmbeddedTextBridge(5), isNull);
    expect(controller.isPlayerDecodedTextSubtitleActive, isFalse);
    expect(await VideoPlayerController().beginEmbeddedTextBridge(0), isNull);
  });
}
