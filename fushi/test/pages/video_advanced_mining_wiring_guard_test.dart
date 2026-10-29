// 视频车道「高级制卡」接线守卫。
//
// 对话框以 `releaseWhenPayloadConsumed: true` 回点弹窗「+」：宿主在**首个 await 之前**
// 同步读完制卡上下文，桥就允许对话框关窗，onClosed 随即把播放头放回查词位置、释放
// 锁帧 / 缓冲副本。所以覆盖项与锁帧必须在同步前缀里读——放到任何 await 之后，读到的
// 就是关窗后的状态（覆盖项丢失、截到试听挪过去的画面）。media_kit 在 headless 测试里
// 起不来，这条时序只能在源码层咬住。

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// [body]（已掩掉注释）里 [needle] 出现在第一个 `await` 之前。
void _expectBeforeFirstAwait(String body, String needle, String reason) {
  final String code = maskComments(body);
  final int at = code.indexOf(needle);
  expect(at, greaterThanOrEqualTo(0), reason: '找不到 $needle');
  final int firstAwait = code.indexOf(RegExp(r'\bawait\b'));
  if (firstAwait >= 0) {
    expect(at, lessThan(firstAwait), reason: reason);
  }
}

void main() {
  late String src;
  setUpAll(() => src = readVideoFushiSource());

  test('本机制卡 / 覆盖：覆盖项在首个 await 之前读取并落到最终区间', () {
    for (final String signature in <String>[
      'Future<MinePopupResult> _onMineEntryImpl(',
      'Future<MinePopupResult> _onUpdateEntryImpl(',
    ]) {
      final String body = methodBody(src, signature);
      _expectBeforeFirstAwait(
        body,
        'MiningRequestOverrides.readFrom(',
        '$signature：覆盖项必须在首个 await 之前同步读取',
      );
      final String compact = compactCode(maskComments(body));
      expect(
        compact,
        contains(
          compactCode(
            'applyVideoMiningOverrides( _resolveVideoMiningRange(controller), '
            'overrides, )',
          ),
        ),
        reason: '$signature：偏移 / 封面帧加在宿主算好的最终区间上',
      );
      expect(compact, contains('overrides:overrides,'));
    }
  });

  test('遥控制卡：手机带来的覆盖项同样在首个 await 之前读取', () {
    final String body = methodBody(
      src,
      'Future<Map<String, Object?>> _mineRemoteVideoCue(',
    );
    // 请求解析（含覆盖项）收进三处遥控绑定共用的同步函数 parseVideoRemoteMineRequest
    // （BUG-3874）：它返回值不是 Future、内部直接 MiningRequestOverrides.readFrom，见
    // video_remote_binding_support_test 的行为测试。这里咬住调用点仍在首个 await 之前。
    _expectBeforeFirstAwait(
      body,
      'parseVideoRemoteMineRequest(',
      '遥控制卡：覆盖项必须在 await _mineVideoCard 之前读取',
    );
    expect(
      compactCode(maskComments(body)),
      contains('finalMiningRequestOverrides?overrides=parsed.overrides;'),
    );
  });

  test('_mineVideoCard：锁帧 / 省略标记都在同步前缀里冻结', () {
    final String body = methodBody(
      src,
      'Future<MinePopupResult> _mineVideoCard(',
    );
    // _mineVideoCard 体里先定义了几个 async 闭包（含 await，但不在同步前缀里执行），
    // 所以这里的「同步前缀」以入队点 `ImmersionMiningEngine().mine(` 为界：入队之前
    // 没有任何顶层 await（既有 BUG-2634 契约），读到的都是点击当下的状态。
    final String code = maskComments(body);
    final int enqueue = code.indexOf('ImmersionMiningEngine().mine(');
    expect(enqueue, greaterThan(0));
    for (final String needle in <String>[
      'advancedSession?.lookupFrame',
      'resolveVideoMiningImageMode(',
      'advancedSession?.takeSnapshotCovering(',
    ]) {
      final int at = code.indexOf(needle);
      expect(at, greaterThanOrEqualTo(0), reason: '找不到 $needle');
      expect(at, lessThan(enqueue), reason: '$needle 必须在入队前同步读取');
    }
    final String compact = compactCode(maskComments(body));
    expect(compact, contains('omitAudio:omitAudio,'));
    expect(compact, contains('omitCover:omitCover,'));
    // 不要图片时不启动现场截图。
    expect(compact, contains('forceSubtitleStart||omitCover'));
    // 不再直接读设置值当图片方式（覆盖项会被绕开）。
    expect(
      compact,
      isNot(contains('finalVideoMiningImageModeimageMode=forceSubtitleStart')),
    );
  });

  test('对话框打开时在任何 await 之前锁住查词画面', () {
    final String body = methodBody(
      src,
      'Future<AdvancedMiningSections> _buildAdvancedMiningSectionsImpl(',
    );
    _expectBeforeFirstAwait(
      body,
      'controller.screenshot()',
      '锁帧必须在任何试听之前（同步前缀里）启动',
    );
    _expectBeforeFirstAwait(
      body,
      '_advancedMiningSession = session;',
      '会话必须在同步前缀里挂上，确认制卡时才读得到',
    );
  });

  test('试听 / 区间描述与写卡同源', () {
    final String window = compactCode(
      maskComments(
        methodBody(src, 'AdvancedMiningAudioWindow? _videoMiningAudioWindow('),
      ),
    );
    expect(
      window,
      contains(
        compactCode(
          'applyVideoMiningOverrides( _resolveVideoMiningRange(controller),',
        ),
      ),
      reason: '描述区间必须与写卡调同一对函数',
    );
    final String preview = maskComments(
      methodBody(src, 'Future<RangePlayback?> _previewVideoMiningAudio('),
    );
    expect(preview, contains('_videoMiningAudioWindow('));
    // 交回区间播放的句柄：对话框的试听按钮在播完 / 被打断时据此复位（FDN66-xurt）。
    expect(preview, contains('return controller.playRangeMs('));
    // 旧「调整上下文」试听也改走同一个最终区间（BUG-3350：曾按 cue 边界放、缺首尾留白）。
    expect(
      maskComments(
        methodBody(src, 'Future<bool> _previewSentenceContextAudio('),
      ),
      contains('_previewVideoMiningAudio('),
    );
    expect(src, isNot(contains('_replaySubtitleSpan(')));
  });

  test('遥控试听与遥控写卡同一个窗口（含首尾留白）', () {
    final String code = compactCode(maskComments(src));
    expect(
      code,
      contains('previewAudio:(VideoRemoteCueanchor,intstartMs,intendMs)async{'),
    );
    expect(
      compactCode(
        maskComments(
          methodBody(src, 'Future<Map<String, Object?>> _mineRemoteVideoCue('),
        ),
      ),
      contains('_remoteVideoMiningWindow('),
    );
    expect(code, contains('stopAudio:controller.stopPlayRange,'));
  });

  test('对话框关闭：停试听、放回查词位置、释放会话', () {
    final String body = maskComments(
      methodBody(src, 'Future<void> _closeAdvancedMiningSession('),
    );
    expect(body, contains('session.release();'));
    expect(body, contains('controller.stopPlayRange()'));
    expect(body, contains('controller.seekMs(lookupMs)'));
    // 查词那一刻记下位置。
    expect(
      maskComments(methodBody(src, 'Future<void> _lookupAt(')),
      contains('_lastLookupPositionMs = controller.positionMs;'),
    );
  });
}
