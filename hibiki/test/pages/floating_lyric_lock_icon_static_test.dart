import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const String servicePath =
      'android/app/src/main/java/app/hibiki/reader/FloatingLyricService.java';
  const String baseServicePath =
      'android/app/src/main/java/app/hibiki/reader/BaseFloatingService.java';
  const String activityPath =
      'android/app/src/main/java/app/hibiki/reader/MainActivity.java';

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

  test('position lock only disables drag, not tap lookup or controls', () {
    final String serviceSource = File(servicePath).readAsStringSync();
    final String baseSource = File(baseServicePath).readAsStringSync();
    final String touchSource = _functionSource(
      baseSource,
      'protected void setupDragListener() {',
      '    // ── Position persistence',
    );
    final String tapSource = _functionSource(
      serviceSource,
      'private void handleTap(MotionEvent event) {',
      'private int getCharIndexAt',
    );
    final String controlSource = _functionSource(
      serviceSource,
      'private void onControlClick(String action) {',
      '    // ── Style application',
    );

    expect(
      touchSource,
      isNot(contains('if (isDragLocked()) return true;')),
      reason: '锁定位置不能在触摸入口吞掉普通点击，否则字幕点击查词也会被锁住。',
    );
    expect(
      touchSource,
      contains('if (isDragging && !isDragLocked())'),
      reason: '拖动更新时才检查位置锁；锁住后仍可分辨 tap 和 drag。',
    );
    expect(
      touchSource,
      contains(
          'if (!isDragLocked()) {\n                                savePosition();'),
      reason: '位置锁下不保存拖动位置，但普通 tap 仍会进入 onOverlayTapped。',
    );
    expect(
      tapSource,
      contains('if (!clickLookupEnabled) return;'),
      reason: '点击查词应由独立开关控制，不由位置锁隐式控制。',
    );
    expect(
      controlSource,
      isNot(contains('if (isLocked && !"toggleLock".equals(action)) return;')),
      reason: '位置锁不应拦截前后句/播放暂停/关闭等进度控制。',
    );
  });

  test('floating lyric starts with seeded theme and lookup options', () {
    final String serviceSource = File(servicePath).readAsStringSync();
    final String activitySource = File(activityPath).readAsStringSync();
    final String onCreateSource = _functionSource(
      serviceSource,
      'public void onCreate() {',
      '    @Override\n    public void onDestroy() {',
    );
    final String showSource = _functionSource(
      activitySource,
      'case "show": {',
      '                    case "hide": {',
    );

    expect(
      onCreateSource,
      contains('readInitialState();\n        super.onCreate();'),
      reason: 'Service 必须在 createContentView/addView 前读取初始主题色。',
    );
    expect(
      showSource,
      contains('persistFloatingLyricOptions(call.arguments);'),
      reason: 'Dart show() 传入的主题色/点击查词选项要先落到原生 prefs。',
    );
    expect(
      serviceSource,
      contains('setClickLookupEnabled(boolean enabled)'),
      reason: '原生浮层需要独立接收点击查词开关。',
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
