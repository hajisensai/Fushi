/// 漫画句序驱动里与音源无关的那部分：显示当前句（多块高亮 + 必要时翻页）、区分
/// 「自己翻的页」与「用户翻的页」、打断代数。
///
/// 两种音源共用：现场合成（`MangaReadAloudController`，边合成边播）与成品音频
/// （`MangaAudioPlaybackDriver`，由 `AudiobookSession` 的位置流驱动）。它们各自决定
/// 「下一句是哪句」，显示与翻页判定都走这里，所以两种模式下「读到哪句框哪几块、
/// 同一 spread 内的页变化不算用户翻页」是同一套语义（webtoon 下 spread 只有一页，
/// 见 [MangaReadAloudHost.isSameSpread]）。
library;

import 'package:fushi/src/media/manga/reader/manga_read_aloud_controller.dart'
    show MangaReadAloudHost;

class MangaSentenceFollower {
  MangaSentenceFollower(this._host);

  final MangaReadAloudHost _host;

  /// [show] 前记下的目标页：这一 spread 内的页变化是自己翻的。
  int? _expectedPage;

  /// 每次打断（切句 / 跳页 / 停止）+1；在途的 [show] 落定时代数变了就作废。
  int _generation = 0;

  int get generation => _generation;
  int? get expectedPage => _expectedPage;

  /// 打断：在途的显示作废，返回新代数。
  int interrupt() => ++_generation;

  bool isCurrent(int generation) => generation == _generation;

  /// 高亮第 [page] 页的块 [blocks]（空 = 只翻到该页、清高亮）；不在当前屏时宿主先翻
  /// 过去。返回显示落定时这次显示是否仍有效（期间没被打断）。
  Future<bool> show(int page, List<int> blocks) async {
    final int generation = _generation;
    _expectedPage = page;
    await _host.show(page, blocks);
    return isCurrent(generation);
  }

  /// 只在当前屏上高亮、不翻页：[page] 不在读者眼前的 spread 时清高亮（关掉「跟随
  /// 翻页」时用）。
  Future<void> highlightInPlace(int page, List<int> blocks) async {
    if (_host.isSameSpread(page, _host.visiblePage)) {
      await _host.show(page, blocks);
    } else {
      await _host.clearHighlight();
    }
  }

  /// 页变化是不是自己 [show] 翻过去的（落在目标页同一 spread 内）。
  bool isOwnPageChange(int page) {
    final int? expected = _expectedPage;
    return expected != null && _host.isSameSpread(page, expected);
  }

  /// 用户翻到 [page]：之后这一 spread 内的页变化都算已知。
  void acceptPage(int page) => _expectedPage = page;

  void reset() => _expectedPage = null;
}
