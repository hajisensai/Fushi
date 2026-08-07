import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';

/// Source guards for TODO-502: video speed changes must feel immediate.
///
/// UI state updates optimistically, controller speed is sent immediately, and
/// only durable preference writes are trailing-debounced/flushed with the same
/// lifecycle coverage as video volume.
///
/// TODO-590 batch12: the speed methods (_setSpeed / persistence pair /
/// long-press trio / _adjustSpeed) were extracted to
/// video_fushi/speed.part.dart, so the page source is read through the merged
/// corpus (main shell + parts). The lone _setSpeed `setState(() {})` rebuild is
/// now routed through the shell `_rebuild(() {})` forwarder (extensions cannot
/// call @protected State.setState) — behaviour-identical, so the assertion
/// tracks the new form.
void main() {
  // 阶段B：倍速行声明移入 settings_schema_video.dart（'video.player.speed'），
  // onPreviewSpeed/onSetSpeed 回调声明移入类型化 VideoQuickSettingsHost；
  // 第一个测试改锁这两个新位置（保护不变：拖动实时预览、松手才落盘）。
  final File schema = File('lib/src/settings/settings_schema_video.dart');
  final File host = File('lib/src/media/video/video_quick_settings_host.dart');

  late String pageSrc;
  late String schemaSrc;
  late String hostSrc;

  setUpAll(() {
    expect(schema.existsSync(), isTrue);
    expect(host.existsSync(), isTrue);
    pageSrc = readVideoFushiSource();
    schemaSrc = schema.readAsStringSync();
    hostSrc = host.readAsStringSync();
  });

  String pageRegion(String startSig, String endSig) =>
      _region(pageSrc, startSig, endSig);

  test('settings speed slider has a live preview callback before commit', () {
    expect(hostSrc.contains('required this.onPreviewSpeed'), isTrue);
    expect(
      hostSrc.contains(
        'final Future<void> Function(double speed) onPreviewSpeed',
      ),
      isTrue,
    );

    // schema 里的倍速行：onChanged 走 onPreviewSpeed（吸附后即时下发、不落盘），
    // onChangeEnd 走 onSetSpeed（最终提交 + 持久化）。
    final String speedRow = _region(
      schemaSrc,
      "id: 'video.player.speed'",
      "id: 'video.playback.speed_step'",
    );
    expect(speedRow.contains('onPreviewSpeed(snapVideoSpeed(v))'), isTrue,
        reason:
            'onChanged must preview snapped speed without waiting for DB commit');
    expect(speedRow.contains('onSetSpeed(snapVideoSpeed(v))'), isTrue,
        reason: 'onChangeEnd remains the final commit path');
    final int previewIdx = speedRow.indexOf('onChanged:');
    final int commitIdx = speedRow.indexOf('onChangeEnd:');
    expect(previewIdx, greaterThanOrEqualTo(0));
    expect(commitIdx, greaterThan(previewIdx),
        reason: 'preview (onChanged) precedes commit (onChangeEnd)');
  });

  test('video page wires speed preview as non-persistent and commit as durable',
      () {
    final String builder = pageRegion(
      'Widget _buildVideoQuickSettingsSheet() {',
      'void _showPlayerSettings',
    );
    expect(
      builder.contains(
        'onPreviewSpeed: (double v) => _setSpeed(v, persist: false),',
      ),
      isTrue,
    );
    expect(builder.contains('onSetSpeed: _setSpeed'), isTrue);
  });

  test('_setSpeed updates UI before controller and only debounces persistence',
      () {
    final String body = pageRegion(
      'Future<void> _setSpeed(',
      'void _handleVideoLongPressStart(',
    );

    expect(body.contains('final bool changed ='), isTrue,
        reason:
            '_setSpeed needs to distinguish same-value durable commit from no-op preview');
    expect(body.contains('if (!changed && !persist) return;'), isTrue);
    expect(body.contains('_playbackSpeed = clamped;'), isTrue);
    // BUG-965：全页重建受 rebuild 门控（默认 true）；长按拖动热路径传 false，
    // 省掉每 0.1x 步进的全页 setState，避免掉帧、拖不流畅。
    expect(body.contains('bool rebuild = true'), isTrue,
        reason: '_setSpeed 需暴露 rebuild 开关，供长按拖动热路径关闭全页重建');
    expect(body.contains('if (rebuild && mounted) _rebuild(() {});'), isTrue);
    expect(body.contains('await _controller?.setSpeed(clamped);'), isTrue);
    expect(body.contains('_queuePersistVideoSpeed(clamped);'), isTrue);
    expect(body.contains('appModel.prefsRepo.setPref(_speedPrefKey, clamped)'),
        isFalse,
        reason: '_setSpeed must not synchronously wait for DB persistence');

    final int stateIndex =
        body.indexOf('if (rebuild && mounted) _rebuild(() {});');
    final int controllerIndex =
        body.indexOf('await _controller?.setSpeed(clamped);');
    final int queueIndex = body.indexOf('_queuePersistVideoSpeed(clamped);');
    expect(stateIndex, lessThan(controllerIndex),
        reason: 'UI must update before awaiting controller.setSpeed');
    expect(queueIndex, greaterThan(controllerIndex),
        reason: 'durable speed commit queues after issuing controller speed');
  });

  test('speed persistence debounce is flushed on lifecycle, exit and dispose',
      () {
    expect(pageSrc.contains('double? _pendingSpeedPersist'), isTrue);
    expect(pageSrc.contains('Timer? _speedPersistDebounce'), isTrue);
    expect(
        pageSrc.contains('void _queuePersistVideoSpeed(double speed)'), isTrue);
    expect(pageSrc.contains('Future<void> _flushPersistedVideoSpeed() async'),
        isTrue);

    final String lifecycle = pageRegion(
      'void didChangeAppLifecycleState(AppLifecycleState state) {',
      'Future<void> _flushAllForProcessExit() async {',
    );
    expect(lifecycle.contains('_flushPersistedVideoSpeed()'), isTrue);

    final String exitFlush = pageRegion(
      'Future<void> _flushAllForProcessExit() async {',
      'Future<void> _init() async {',
    );
    expect(exitFlush.contains('await _flushPersistedVideoSpeed();'), isTrue);

    final String disposeBody = pageRegion(
      'void dispose() {',
      'bool _overlayInert = false;',
    );
    expect(disposeBody.contains('_speedPersistDebounce?.cancel();'), isTrue);
    expect(disposeBody.contains('_flushPersistedVideoSpeed()'), isTrue);
  });

  test('long-press temporary speed is non-persistent and skips full rebuild',
      () {
    final String longPress = pageRegion(
      'void _handleVideoLongPressStart(',
      'Future<void> _adjustSpeed(',
    );
    // BUG-965：start/move 传 rebuild: false（跟随徽章实时渲染倍速，页面免高频全页
    // setState），拖动才顺滑。
    expect(
        longPress.contains('_setSpeed(speed, persist: false, rebuild: false)'),
        isTrue,
        reason: 'start 临时加速不触发全页重建');
    expect(
        longPress
            .contains('_setSpeed(snapped, persist: false, rebuild: false)'),
        isTrue,
        reason: 'move 拖动热路径每步不触发全页重建');
    // 松手恢复原速走默认 rebuild（一次性把倍速按钮标签对账回恢复速）。
    expect(longPress.contains('_setSpeed(previous, persist: false)'), isTrue);
  });
}

String _region(String source, String startSig, String endSig) {
  final int start = source.indexOf(startSig);
  expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
  final int end = source.indexOf(endSig, start + startSig.length);
  expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
  return source.substring(start, end);
}
