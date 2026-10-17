import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'reader_fushi_page_source_corpus.dart';

/// 阅读计时开始方式（2026-10-05）的页面接线守卫。判据是纯逻辑（见
/// `test/stats/reader_study_clock_start_mode_test.dart`），这里钉的是：打开书按设置
/// 建门、所有落定都喂门、有声书播放喂门、手动停 / 续经门翻旗、起表仍只经统一判据。
void main() {
  final String corpus = maskComments(readReaderPageSource());

  String body(String signature) {
    final int start = corpus.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: '找不到 $signature');
    final int end = corpus.indexOf('\n  }\n', start);
    return corpus.substring(start, end);
  }

  test('initState 按设置建开始方式门，暂停旗只读门', () {
    expect(
      body('  void initState() {'),
      contains('_studyClockStartGate = ReaderStudyClockStartGate(\n'
          '      appModelNoUpdate.readerStudyClockStartMode,'),
    );
    expect(
      corpus,
      contains(
          'bool get _studyClockManualPause => _studyClockStartGate.manualPause;'),
    );
    expect(
        corpus, isNot(contains(RegExp(r'_studyClockManualPause\s*=(?![=>])'))),
        reason: '暂停旗只有门一个持有者，页面不许再自己写一份');
  });

  test('进度落定先喂门再 arrive（BUG-3100：打开那页翻走时计入）', () {
    final String refresh = body('  Future<void> _refreshProgress() async {');
    expect(refresh, contains('arriveReadUnitThroughStartGate('));
    expect(refresh, contains('ledger: _readLedger,'));
    expect(refresh, contains('gate: _studyClockStartGate,'));
    expect(
      refresh,
      isNot(contains('_readLedger.arrive(unitStart, unitEnd);')),
      reason: '落定只经 arriveReadUnitThroughStartGate（先门后账本），不许再裸 arrive',
    );
  });

  test('喂门的两处只在门放行后经统一判据起表', () {
    expect(body('  void _onStudyClockAutoStartOnTurn() {'),
        contains('_startStudyClockFromGate();'));
    expect(body('  void _noteAudiobookPlayingForStudyClock(bool playing) {'),
        contains('_studyClockStartGate.noteAudiobookPlaying(playing)'));
    final String start = body('  void _startStudyClockFromGate() {');
    expect(start, contains('_ensureStudyClock();'));
    expect(start, contains('_syncStudyClockRunState();'));
    expect(start, isNot(contains('.start()')));
  });

  test('手动停 / 续经门翻旗', () {
    expect(body('  void _toggleStudyClockManualPause() {'),
        contains('_studyClockStartGate.toggleManualPause()'));
  });

  test('设置项在阅读设置的统计分组，键名稳定', () {
    final String schema = File('lib/src/settings/settings_schema_reading.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final int section = schema.indexOf("id: 'reading.section.statistics'");
    final int item = schema.indexOf("id: 'reading.stats_clock_start_mode'");
    expect(section, greaterThanOrEqualTo(0));
    expect(item, greaterThan(section));
    expect(schema.indexOf('SettingsSection(', section + 1), greaterThan(item),
        reason: '必须落在统计分组内');
  });
}
