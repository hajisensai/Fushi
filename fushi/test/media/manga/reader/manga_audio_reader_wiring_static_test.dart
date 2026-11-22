// 有声漫画在阅读器里的四处接线（反馈 WrLFAXNkSw / Yh8ukM6J_i）：查词暂停的时点、退出
// 即停、键盘接管、滚动收起界面的落点。
//
// 这几处都在 `_MangaFushiPageState` / `_MangaReadAloudSupport` 的私有方法里，依赖正文
// WebView 与有声书会话，host 测试环境起不来整页，故落在源码守卫层（与
// `audiobook_exit_stop_policy_static_test.dart`、`manga_audio_playback_ocr_guard_test.dart`
// 同范式）。各自的判据（[MangaLookupPause]、[resolveMangaAudioKeyTakeover]、
// [mangaScrollHideEffect]）另有行为测试。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String _read(List<String> parts) => File(
  p.joinAll(<String>['lib', 'src', 'media', 'manga', ...parts]),
).readAsStringSync();

/// `signature` 开始到下一个同缩进的 `}` 为止的方法体。
String _methodBody(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 $signature');
  final int end = source.indexOf('\n  }\n', start);
  expect(end, greaterThan(start));
  return source.substring(start, end);
}

void main() {
  final String page = _read(<String>['reader', 'manga_fushi_page.dart']);
  final String readAloud = _read(<String>[
    'reader',
    'manga_fushi',
    'read_aloud.part.dart',
  ]);

  test('查词暂停在发起查词时同步按住，不等弹窗渲染信号（与小说 _pauseForLookup 同一时点）', () {
    final String select = _methodBody(
      page,
      'Future<void> processMangaSelection(ReaderSelectionData data) async {',
    );
    final int opened = select.indexOf(
      '_readAloud.lookupOpened(MangaLookupSource.page)',
    );
    expect(opened, greaterThanOrEqualTo(0), reason: '发起查词处必须按住播放');
    // 路由到副屏的查词由 companion 来源按住：页内来源只在没路由走时登记，否则页内
    // 来源一直挂着，副屏关掉也放不了手。
    expect(
      select.indexOf('routeCompanionLookup('),
      lessThan(opened),
      reason: '先判副屏路由，再按住页内来源',
    );
    expect(
      opened,
      lessThan(select.indexOf('await searchDictionaryResult(')),
      reason: '必须在等查词结果之前同步暂停',
    );
    expect(
      _methodBody(page, 'void onDictionaryPopupRendered(int index) {'),
      isNot(contains('lookupOpened')),
      reason: '渲染信号在热槽复用 / 超时兜底路径上不来或来得很晚，不能当暂停时点',
    );
    expect(
      _methodBody(page, 'void onAllPopupsDismissed() {'),
      contains('_readAloud.lookupClosed(MangaLookupSource.page, resume: true)'),
    );
  });

  test('退出阅读器：没开「退出后续播」就停掉成品音频会话，开着只解宿主', () {
    final String stop = _methodBody(
      readAloud,
      'void stopAudioUnlessBackground(String logTag) {',
    );
    expect(stop, contains('audiobookBackgroundPlay'));
    expect(stop, contains('identical(_session.companion, driver)'));
    expect(
      stop.indexOf('audiobookBackgroundPlay'),
      lessThan(stop.indexOf('_session.stop()')),
      reason: 'stop 必须在偏好门控之后，不能无条件停',
    );
    expect(stop, isNot(contains('await _session.stop()')));
    final String dispose = _methodBody(readAloud, '  void dispose() {');
    expect(dispose, contains('stopAudioUnlessBackground('));
    expect(
      dispose.indexOf('stopAudioUnlessBackground('),
      lessThan(dispose.indexOf('_detachAudio()')),
      reason: 'dispose 先按偏好停，再解宿主',
    );
    final String pop = _methodBody(
      page,
      'Future<void> onSourcePagePop() async {',
    );
    final int popStop = pop.indexOf('_readAloud.stopAudioUnlessBackground(');
    expect(popStop, greaterThanOrEqualTo(0));
    expect(
      popStop,
      lessThan(pop.indexOf(RegExp(r'^\s+await ', multiLine: true))),
      reason: '第一个 await 之前停，书架迷你条首帧就见空会话',
    );
  });

  test('键盘路径经 resolveMangaAudioKeyTakeover 让有声接管空格 / 左右键', () {
    final String resolve = _methodBody(
      page,
      'MangaReaderInputAction? _resolveMangaKeyAction(',
    );
    expect(resolve, contains('resolveMangaAudioKeyTakeover('));
    expect(resolve, contains('audioActive: _readAloud.active'));
    expect(resolve, contains('action: audio ?? corrected'));
  });

  test('滚动收起界面经 mangaScrollHideEffect 分流，悬浮态不碰持久隐藏', () {
    expect(page, contains('_onReaderScrollHide(args.first as bool)'));
    final String handler = _methodBody(
      page,
      'void _onReaderScrollHide(bool hide) {',
    );
    expect(handler, contains('mangaScrollHideEffect('));
    expect(
      page,
      isNot(contains('if (_chromeVisible == hide) _toggleMangaChrome();')),
    );
  });
}
