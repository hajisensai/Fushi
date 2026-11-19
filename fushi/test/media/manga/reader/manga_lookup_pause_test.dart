// 漫画阅读器「查词时暂停」（BUG-4907）：查词弹窗出现按住在播的朗读 / 漫画有声，整栈
// 关闭时恢复；本来停着的不动、开关关着不动、多层弹窗只按一次、用户停掉后关弹窗不恢复。
import 'package:fushi/src/media/manga/reader/manga_lookup_pause.dart';
import 'package:test/test.dart';

class _Playback implements MangaLookupPausable {
  _Playback({required this.isRunning});

  @override
  bool isRunning;
  int pauses = 0;
  int resumes = 0;

  @override
  void pause() {
    pauses++;
    isRunning = false;
  }

  @override
  void resume() {
    resumes++;
    isRunning = true;
  }
}

void main() {
  test('在播：查词弹窗出现即暂停，整栈关闭后恢复', () {
    final MangaLookupPause hold = MangaLookupPause();
    final _Playback playback = _Playback(isRunning: true);
    hold.lookupOpened(playback, enabled: true);
    expect(playback.pauses, 1);
    expect(hold.held, isTrue);
    // 嵌套弹窗再渲染一层：不重复按。
    hold.lookupOpened(playback, enabled: true);
    expect(playback.pauses, 1);
    hold.lookupClosed(playback);
    expect(playback.resumes, 1);
    expect(hold.held, isFalse);
    // 再关一次（多余的关闭回调）不重复恢复。
    hold.lookupClosed(playback);
    expect(playback.resumes, 1);
  });

  test('查词前本来就停着：不按也不恢复', () {
    final MangaLookupPause hold = MangaLookupPause();
    final _Playback playback = _Playback(isRunning: false);
    hold.lookupOpened(playback, enabled: true);
    hold.lookupClosed(playback);
    expect(playback.pauses, 0);
    expect(playback.resumes, 0);
  });

  test('「查词时暂停」关着 / 没有音源：什么都不做', () {
    final MangaLookupPause hold = MangaLookupPause();
    final _Playback playback = _Playback(isRunning: true);
    hold.lookupOpened(playback, enabled: false);
    hold.lookupOpened(null, enabled: true);
    hold.lookupClosed(playback);
    expect(playback.pauses, 0);
    expect(playback.resumes, 0);
  });

  test('查词期间用户停掉了播放：关弹窗不再恢复', () {
    final MangaLookupPause hold = MangaLookupPause();
    final _Playback playback = _Playback(isRunning: true);
    hold.lookupOpened(playback, enabled: true);
    hold.drop();
    hold.lookupClosed(playback);
    expect(playback.resumes, 0);
  });
}
