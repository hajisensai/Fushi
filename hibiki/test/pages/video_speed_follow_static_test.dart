import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guards for TODO-502: video speed changes must feel immediate.
///
/// UI state updates optimistically, controller speed is sent immediately, and
/// only durable preference writes are trailing-debounced/flushed with the same
/// lifecycle coverage as video volume.
void main() {
  final File page =
      File('lib/src/pages/implementations/video_hibiki_page.dart');
  final File sheet =
      File('lib/src/media/video/video_quick_settings_sheet.dart');

  late String pageSrc;
  late String sheetSrc;

  setUpAll(() {
    expect(page.existsSync(), isTrue);
    expect(sheet.existsSync(), isTrue);
    pageSrc = page.readAsStringSync();
    sheetSrc = sheet.readAsStringSync();
  });

  String pageRegion(String startSig, String endSig) =>
      _region(pageSrc, startSig, endSig);

  String sheetRegion(String startSig, String endSig) =>
      _region(sheetSrc, startSig, endSig);

  test('settings speed slider has a live preview callback before commit', () {
    expect(sheetSrc.contains('required this.onPreviewSpeed'), isTrue);
    expect(
      sheetSrc.contains(
        'final Future<void> Function(double speed) onPreviewSpeed',
      ),
      isTrue,
    );

    final String speedRow = sheetRegion(
      'Widget _buildSpeedRow() {',
      'double _snapSpeed(double v)',
    );
    expect(
        speedRow.contains('unawaited(widget.onPreviewSpeed(snapped))'), isTrue,
        reason:
            'onChanged must preview snapped speed without waiting for DB commit');
    expect(speedRow.contains('await widget.onSetSpeed(snapped)'), isTrue,
        reason: 'onChangeEnd remains the final commit path');
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
      'Future<void> _setSpeed(double speed, {bool persist = true}) async {',
      'void _handleVideoLongPressStart(',
    );

    expect(body.contains('final bool changed ='), isTrue,
        reason:
            '_setSpeed needs to distinguish same-value durable commit from no-op preview');
    expect(body.contains('if (!changed && !persist) return;'), isTrue);
    expect(body.contains('_playbackSpeed = clamped;'), isTrue);
    expect(body.contains('if (mounted) setState(() {});'), isTrue);
    expect(body.contains('await _controller?.setSpeed(clamped);'), isTrue);
    expect(body.contains('_queuePersistVideoSpeed(clamped);'), isTrue);
    expect(body.contains('appModel.prefsRepo.setPref(_speedPrefKey, clamped)'),
        isFalse,
        reason: '_setSpeed must not synchronously wait for DB persistence');

    final int stateIndex = body.indexOf('if (mounted) setState(() {});');
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

  test('long-press temporary speed remains non-persistent', () {
    final String longPress = pageRegion(
      'void _handleVideoLongPressStart(',
      'Future<void> _adjustSpeed(',
    );
    expect(longPress.contains('_setSpeed(speed, persist: false)'), isTrue);
    expect(longPress.contains('_setSpeed(snapped, persist: false)'), isTrue);
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
