import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const String servicePath =
      'android/app/src/main/java/app/hibiki/reader/FloatingLyricService.java';

  test('floating lyric lock button icon reflects current lock state', () {
    final String source = File(servicePath).readAsStringSync();
    final String createSource = _functionSource(
      source,
      'protected View createContentView() {',
      'protected Notification buildNotification() {',
    );
    final String lockSource = _functionSource(
      source,
      'private void applyLockButton() {',
      'private void applyPlayPauseButton() {',
    );

    expect(
      createSource,
      contains('R.drawable.ic_floating_lock_open'),
      reason: 'The initial unlocked overlay should show an open lock.',
    );
    expect(
      lockSource,
      contains(
        'isLocked ? R.drawable.ic_floating_lock : R.drawable.ic_floating_lock_open',
      ),
      reason: 'The visual icon should show the current lock state.',
    );
    expect(
      lockSource,
      contains('isLocked ? unlockLabel : lockLabel'),
      reason: 'The accessibility label still describes the toggle action.',
    );
    expect(
      lockSource,
      contains('isLocked ? activeColor : buttonTextColor'),
      reason: 'The locked state remains visually active.',
    );
  });
}

String _functionSource(
  String source,
  String startToken,
  String endToken,
) {
  final int start = source.indexOf(startToken);
  final int end = source.indexOf(endToken, start + startToken.length);
  expect(start, isNonNegative, reason: 'missing $startToken');
  expect(end, greaterThan(start),
      reason: 'missing $endToken after $startToken');
  return source.substring(start, end);
}
