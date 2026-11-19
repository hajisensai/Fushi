// 漫画阅读器「查词时暂停」：查词出现按住在播的朗读 / 漫画有声，所有查词都关掉才恢复。
// - BUG-4907：页内弹窗；本来停着的不动、开关关着不动、多层弹窗只按一次、用户停掉后
//   关弹窗不恢复。
// - BUG-4908：第二块屏的伴侣查词与页内弹窗是两个来源，一边关了另一边还开着就继续按住；
//   副屏带着开着的查词走了只放手不起播。
// - BUG-4909：查后从句首重播——主屏选中的句子交给这次查词按住的播放，副屏面板自己
//   发起的查词没有被查句（退到当前句）。
import 'package:fushi/src/media/manga/reader/manga_lookup_pause.dart';
import 'package:test/test.dart';

class _Playback implements MangaLookupPausable {
  _Playback({required this.isRunning});

  @override
  bool isRunning;
  int pauses = 0;
  final List<({bool restart, MangaLookupSentence? sentence})> resumes =
      <({bool restart, MangaLookupSentence? sentence})>[];

  @override
  void pause() {
    pauses++;
    isRunning = false;
  }

  @override
  void resume({required bool restartSentence, MangaLookupSentence? sentence}) {
    resumes.add((restart: restartSentence, sentence: sentence));
    isRunning = true;
  }
}

const MangaLookupSource _page = MangaLookupSource.page;
const MangaLookupSource _companion = MangaLookupSource.companion;

void _close(
  MangaLookupPause hold,
  MangaLookupSource source,
  _Playback? playback, {
  bool resume = true,
  bool restart = false,
}) => hold.lookupClosed(
  source,
  playback,
  resume: resume,
  restartSentence: restart,
);

void main() {
  group('页内弹窗（BUG-4907）', () {
    test('在播：查词弹窗出现即暂停，整栈关闭后原地续播', () {
      final MangaLookupPause hold = MangaLookupPause();
      final _Playback playback = _Playback(isRunning: true);
      hold.lookupOpened(_page, playback, enabled: true);
      expect(playback.pauses, 1);
      expect(hold.held, isTrue);
      // 嵌套弹窗再渲染一层：不重复按。
      hold.lookupOpened(_page, playback, enabled: true);
      expect(playback.pauses, 1);
      _close(hold, _page, playback);
      expect(playback.resumes.single.restart, isFalse);
      expect(hold.held, isFalse);
      // 多余的关闭回调不重复恢复。
      _close(hold, _page, playback);
      expect(playback.resumes, hasLength(1));
    });

    test('查词前本来就停着：不按也不恢复', () {
      final MangaLookupPause hold = MangaLookupPause();
      final _Playback playback = _Playback(isRunning: false);
      hold.lookupOpened(_page, playback, enabled: true);
      _close(hold, _page, playback);
      expect(playback.pauses, 0);
      expect(playback.resumes, isEmpty);
    });

    test('「查词时暂停」关着 / 没有音源：什么都不做', () {
      final MangaLookupPause hold = MangaLookupPause();
      final _Playback playback = _Playback(isRunning: true);
      hold.lookupOpened(_page, playback, enabled: false);
      hold.lookupOpened(_page, null, enabled: true);
      _close(hold, _page, playback);
      expect(playback.pauses, 0);
      expect(playback.resumes, isEmpty);
    });

    test('查词期间用户停掉了播放：关弹窗不再恢复', () {
      final MangaLookupPause hold = MangaLookupPause();
      final _Playback playback = _Playback(isRunning: true);
      hold.lookupOpened(_page, playback, enabled: true);
      hold.drop();
      _close(hold, _page, playback);
      expect(playback.resumes, isEmpty);
    });
  });

  group('第二块屏（BUG-4908）', () {
    test('副屏查词同样按住，关掉恢复', () {
      final MangaLookupPause hold = MangaLookupPause();
      final _Playback playback = _Playback(isRunning: true);
      hold.lookupOpened(_companion, playback, enabled: true);
      expect(playback.pauses, 1);
      _close(hold, _companion, playback);
      expect(playback.resumes, hasLength(1));
    });

    test('两边都开着：先关一边不恢复，全部关掉才恢复（与先后无关）', () {
      for (final List<MangaLookupSource> order in <List<MangaLookupSource>>[
        <MangaLookupSource>[_page, _companion],
        <MangaLookupSource>[_companion, _page],
      ]) {
        final MangaLookupPause hold = MangaLookupPause();
        final _Playback playback = _Playback(isRunning: true);
        hold.lookupOpened(_page, playback, enabled: true);
        hold.lookupOpened(_companion, playback, enabled: true);
        expect(playback.pauses, 1);
        _close(hold, order.first, playback);
        expect(playback.resumes, isEmpty, reason: '$order');
        expect(hold.held, isTrue);
        _close(hold, order.last, playback);
        expect(playback.resumes, hasLength(1), reason: '$order');
      }
    });

    test('副屏带着开着的查词走了（resume=false）：放手但不起播', () {
      final MangaLookupPause hold = MangaLookupPause();
      final _Playback playback = _Playback(isRunning: true);
      hold.lookupOpened(_companion, playback, enabled: true);
      _close(hold, _companion, playback, resume: false);
      expect(hold.held, isFalse);
      expect(playback.resumes, isEmpty);
      // 之后再关页内弹窗也不会凭空恢复。
      _close(hold, _page, playback);
      expect(playback.resumes, isEmpty);
    });
  });

  group('查后从句首重播（BUG-4909）', () {
    const MangaLookupSentence sentence = (pageIndex: 7, blocks: <int>[2, 3]);

    test('主屏选中的句子交给这次查词（页内或副屏）恢复时用', () {
      for (final MangaLookupSource source in MangaLookupSource.values) {
        final MangaLookupPause hold = MangaLookupPause();
        final _Playback playback = _Playback(isRunning: true);
        hold.noteSentence(sentence);
        hold.lookupOpened(source, playback, enabled: true);
        _close(hold, source, playback, restart: true);
        final ({bool restart, MangaLookupSentence? sentence}) r =
            playback.resumes.single;
        expect(r.restart, isTrue, reason: '$source');
        expect(r.sentence, sentence, reason: '$source');
      }
    });

    test('副屏面板自己发起的查词没有被查句：从当前句句首（sentence 为空）', () {
      final MangaLookupPause hold = MangaLookupPause();
      final _Playback playback = _Playback(isRunning: true);
      hold.lookupOpened(_companion, playback, enabled: true);
      _close(hold, _companion, playback, restart: true);
      expect(playback.resumes.single.restart, isTrue);
      expect(playback.resumes.single.sentence, isNull);
    });

    test('句子只属于认领它的那次查词：关掉后不带到下一次', () {
      final MangaLookupPause hold = MangaLookupPause();
      final _Playback playback = _Playback(isRunning: true);
      hold.noteSentence(sentence);
      hold.lookupOpened(_page, playback, enabled: true);
      _close(hold, _page, playback, restart: true);
      playback.isRunning = true;
      hold.lookupOpened(_companion, playback, enabled: true);
      _close(hold, _companion, playback, restart: true);
      expect(playback.resumes.last.sentence, isNull);
    });

    test('开关关着：原地续播', () {
      final MangaLookupPause hold = MangaLookupPause();
      final _Playback playback = _Playback(isRunning: true);
      hold.noteSentence(sentence);
      hold.lookupOpened(_page, playback, enabled: true);
      _close(hold, _page, playback);
      expect(playback.resumes.single.restart, isFalse);
    });
  });
}
