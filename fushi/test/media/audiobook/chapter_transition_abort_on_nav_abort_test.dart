import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../helpers/source_guard.dart';

/// BUG-2529：跨章导航中止必须解除跨章守卫。
///
/// `_chapterTransition` 是「为这一次在飞的跨章导航」竖起来的，唯一的正常解除路径
/// 是 reader 在章节内容就绪后回调 `notifySectionRestoreCompleted`。reader 的
/// `_failNavigation`（装载抛错 / `_navigateToChapterAndWait` 等待超时 /
/// content-ready 兜底超时三份中止的收敛单点）旧实现只解开导航态，守卫就此永久卡
/// true：控制器侧 `_updateCurrentCue` 与 `setChapterCues` 全部早退，当前 cue 冻结在
/// 旧章旧句，上一句/下一句每次都拿冻结索引算目标（到末句就落 `onBoundarySkip` →
/// 又一次注定超时的跨章导航），cue 高亮也不再跟随，且没有任何自愈，直到重开书。
///
/// Android 上「切出去再回来，小说音频的上下句就不动了」走的就是这条：app 切后台后
/// 前台服务里的有声书照常播到下一章、照常竖旗发起跨章导航，而后台 WebView 被
/// Chromium 按不可见文档节流（rAF 冻结、timer 降频，同 BUG-2465 一族），restore 回执
/// 拖过 8s 兜底窗 → 兜底超时摘遮罩并调 `_failNavigation` → 守卫永久卡死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BUG-2529 abortChapterTransition 语义', () {
    test('普通跨章在飞：导航中止解除守卫', () {
      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);

      controller.holdChapterTransition();
      expect(controller.chapterTransitionHeldForTesting, isTrue);

      controller.abortChapterTransition();

      expect(controller.chapterTransitionHeldForTesting, isFalse,
          reason: '导航中止意味着 notifySectionRestoreCompleted 永远不会来，'
              '守卫必须在这里释放，否则 cue 推进永久冻结');
    });

    test('图片章停留序列在途：abort 不得放掉序列自己持的守卫', () {
      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);

      controller.setImageChapterPauseActive(true);
      controller.holdChapterTransition();

      controller.abortChapterTransition();

      expect(controller.chapterTransitionHeldForTesting, isTrue,
          reason: '序列用守卫挡住中间章回执的重入（TODO-1037），'
              '中止其中一章的导航不得把整段序列的守卫一起放掉');

      // 对照组：序列收尾后同一个 abort 正常解除 —— 证明上面断的不是死分支。
      controller.setImageChapterPauseActive(false);
      controller.abortChapterTransition();

      expect(controller.chapterTransitionHeldForTesting, isFalse);
    });
  });

  group('BUG-2529 守卫卡住 = cue 冻结（用户症状的机制）', () {
    test('守卫持住时换 cue 列表不重算当前 cue，解除后立刻重算', () {
      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);

      final List<AudioCue> oldChapter = <AudioCue>[
        _cue('old-0', startMs: 0),
        _cue('old-1', startMs: 1000),
      ];
      controller.setChapterCues(oldChapter);
      expect(controller.currentCue?.text, 'old-0',
          reason: '位置 0 落在首句，正常路径解析得到当前 cue');

      // 跨章导航在飞：守卫竖起，新章 cue 灌进来只换列表、不重算（既有语义）。
      controller.holdChapterTransition();
      final List<AudioCue> newChapter = <AudioCue>[_cue('new-0', startMs: 0)];
      controller.setChapterCues(newChapter);
      expect(controller.currentCue?.text, 'old-0',
          reason: '守卫期间当前 cue 冻结在旧章旧句 —— 卡死时用户看到的正是这个');

      // 导航中止：守卫释放后，下一次列表更新（章节真正落地时的 setChapterCues）
      // 恢复重算，状态机自愈。
      controller.abortChapterTransition();
      controller.setChapterCues(newChapter);

      expect(controller.currentCue?.text, 'new-0',
          reason: '守卫解除后 cue 重算恢复，上下句不再拿冻结索引算目标');
    });
  });

  group('BUG-2529 装配：reader 侧中止路径必须接上守卫解除', () {
    final String navigation = File(
      'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
    ).readAsStringSync();

    test('_failNavigation 解除跨章守卫', () {
      final String body = methodBody(navigation, 'void _failNavigation() {');
      expect(containsIdentifierCall(body, 'abortChapterTransition'), isTrue,
          reason: '_failNavigation 是三份导航中止的收敛单点，'
              '跨章守卫必须在这里释放（BUG-2529）');
    });

    test('content-ready 兜底超时经 _failNavigation 收口', () {
      final String body =
          methodBody(navigation, 'void _startContentReadyTimeout() {');
      expect(containsIdentifierCall(body, '_failNavigation'), isTrue,
          reason: '兜底超时是「WebView 回执永远不来」的那条路径，'
              '它必须走同一个收口点，否则守卫解除绕不到它');
    });

    test('章节装载失败也经 _failNavigation 收口', () {
      final String body = methodBody(
        navigation,
        'Future<void> _navigateToChapter(',
      );
      expect(containsIdentifierCall(body, '_failNavigation'), isTrue,
          reason: '装载抛错同样让回执永不到达，必须走同一收口点');
    });

    test('解除用 abortChapterTransition 而非裸 cancelChapterTransition', () {
      final String controllerSrc = File(
        '../packages/fushi_audio/lib/src/audiobook/audiobook_controller.dart',
      ).readAsStringSync();
      final String body =
          methodBody(controllerSrc, 'void abortChapterTransition() {');
      expect(containsCodeLine(body, 'if (_imageChapterPauseActive) return;'),
          isTrue,
          reason: 'abort 与 cancel 的唯一差别就是尊重图片章停留序列，'
              '这条早退丢了就会复现 TODO-1037 的一步跳过剩余图片章');
    });
  });
}

AudioCue _cue(String text, {required int startMs}) {
  return AudioCue()
    ..id = null
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = text
    ..text = text
    ..startMs = startMs
    ..endMs = startMs + 900
    ..audioFileIndex = 0;
}
