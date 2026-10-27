import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_plan.dart';
import 'package:fushi/src/media/video/theme_song/video_theme_song_tracker.dart';

/// 视频页对声纹识别出的 OP / ED 的自动跳过（作品图谱 L2；跳过按钮与曲名角标已按
/// BUG-3850 删除，守卫 `test/pages/video_skip_chapter_removed_guard_test.dart`）。
///
/// 钉：① 开关关着什么都不做；② 自动跳过落点 = 段尾前 0.5 s，只在刚进段的 3 s 窗口
/// 里触发一次，用户拖回段中不被再次弹走；③ 插入曲永不自动跳；④ 换源解绑旧源。
void main() {
  const ThemeSongSpan op = ThemeSongSpan(
    trackUid: 'op',
    title: '夜明けの窓',
    role: ThemeSongRole.op,
    startMs: 60000,
    endMs: 150000,
    confidence: 0.95,
  );
  const ThemeSongSpan insert = ThemeSongSpan(
    trackUid: 'ins',
    title: '挿入歌',
    role: ThemeSongRole.insert,
    startMs: 600000,
    endMs: 660000,
    confidence: 0.9,
  );
  const ThemeSongSpan ed = ThemeSongSpan(
    trackUid: 'ed',
    title: 'ED 曲',
    role: ThemeSongRole.ed,
    startMs: 1300000,
    endMs: 1390000,
    confidence: 0.9,
  );

  test('开关关着：进 OP / ED 都不跳', () {
    final VideoThemeSongTracker tracker = VideoThemeSongTracker(
      autoSkip: () => false,
      onAutoSkip: (_) => fail('auto skip off'),
    )..setSpans(const <ThemeSongSpan>[op, insert, ed]);
    tracker
      ..onPosition(60100)
      ..onPosition(1300100);
    tracker.dispose();
  });

  test('自动跳过只在刚进段的 3 s 窗口内触发一次；拖回段中不再弹走', () {
    final List<int> autoTargets = <int>[];
    final VideoThemeSongTracker tracker = VideoThemeSongTracker(
      autoSkip: () => true,
      onAutoSkip: autoTargets.add,
    )..setSpans(const <ThemeSongSpan>[op, insert, ed]);
    tracker.onPosition(60200);
    expect(autoTargets, <int>[149500]);
    tracker.onPosition(60300);
    expect(autoTargets, hasLength(1), reason: '同一段只跳一次');
    tracker.onPosition(1300500);
    expect(autoTargets, <int>[149500, 1389500], reason: 'ED 同样跳');
    // 换集重置。
    tracker.setSpans(const <ThemeSongSpan>[op]);
    tracker.onPosition(90000);
    expect(autoTargets, hasLength(2), reason: '段中途进入（拖进度条）不自动跳');
    tracker.onPosition(60100);
    expect(autoTargets, hasLength(3), reason: '换集后同一段首重新可跳');
    // 插入曲永不自动跳。
    tracker.setSpans(const <ThemeSongSpan>[insert]);
    tracker.onPosition(600100);
    expect(autoTargets, hasLength(3));
    tracker.dispose();
  });

  test('开关每次现读：中途打开立即生效', () {
    bool on = false;
    final List<int> autoTargets = <int>[];
    final VideoThemeSongTracker tracker = VideoThemeSongTracker(
      autoSkip: () => on,
      onAutoSkip: autoTargets.add,
    )..setSpans(const <ThemeSongSpan>[op]);
    tracker.onPosition(60100);
    expect(autoTargets, isEmpty);
    on = true;
    tracker.onPosition(60200);
    expect(autoTargets, <int>[149500]);
    tracker.dispose();
  });

  test('跟位置源：attach 后位置事件驱动判定，换源自动解绑旧源', () {
    final ValueNotifier<int?> a = ValueNotifier<int?>(null);
    final ValueNotifier<int?> b = ValueNotifier<int?>(null);
    final List<int> autoTargets = <int>[];
    final VideoThemeSongTracker tracker = VideoThemeSongTracker(
      autoSkip: () => true,
      onAutoSkip: autoTargets.add,
    )..setSpans(const <ThemeSongSpan>[op, ed]);
    tracker.attach(a);
    a.value = 60100;
    expect(autoTargets, <int>[149500]);
    tracker.attach(b);
    a.value = 1300100;
    expect(autoTargets, hasLength(1), reason: '旧源已解绑');
    b.value = 1300100;
    expect(autoTargets, <int>[149500, 1389500]);
    tracker.dispose();
    a.dispose();
    b.dispose();
  });
}
