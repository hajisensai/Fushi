part of '../reader_fushi_page.dart';

/// 本页对桌面控制通道（`fushi_cli reader ...`）的遥控实现，登记进
/// [readerSessionRemotes]（initState 登记、dispose 注销，见 [_ReaderFushiPageState]）。
///
/// 每个动作只转调页内已有执行体：翻页 = 翻页快捷键的 `_paginate`；跳章 = 目录 /
/// 书签跳转的 `_navigateToChapterAndWait`（manual，带章内分数的原子恢复链）；全书
/// 百分比 = 底栏进度条拖动的 `_jumpToGlobalCharOffset`。书没加载好时快照为 null、
/// 动作为 no-op（路由层先看快照再下发）。
class _ReaderPageSessionRemote implements ReaderSessionRemote {
  _ReaderPageSessionRemote(this._state);

  final _ReaderFushiPageState _state;

  EpubBook? get _book => _state.mounted ? _state._book : null;

  @override
  ReaderSessionSnapshot? snapshot() {
    final EpubBook? book = _book;
    if (book == null) return null;
    return ReaderSessionSnapshot(
      kind: ReaderSessionKind.epub,
      bookKey: _state.widget.bookKey,
      title: book.title,
      chapterIndex: _state._currentChapter,
      chapterCount: book.chapters.length,
      chapterProgress: _state._lastProgressSection == _state._currentChapter
          ? _state._lastProgressValue
          : 0,
      currentChars: _state._progressCurrentChars,
      totalChars: _state._progressTotalChars,
      contentReady: _state._readerContentReady,
    );
  }

  @override
  Future<void> turnPage({required bool forward}) async {
    if (_book == null) return;
    await _state._paginate(
      forward
          ? ReaderNavigationDirection.forward
          : ReaderNavigationDirection.backward,
    );
  }

  @override
  Future<bool> goToChapter(int chapterIndex, {double progress = 0}) async {
    final EpubBook? book = _book;
    if (book == null ||
        chapterIndex < 0 ||
        chapterIndex >= book.chapters.length) {
      return false;
    }
    return _state._navigateToChapterAndWait(
      chapterIndex,
      manual: true,
      progress: progress.clamp(0.0, 1.0),
    );
  }

  @override
  Future<bool> goToBookPercent(double percent) async {
    if (_book == null) return false;
    final int? total = _state._progressTotalChars;
    if (total == null || total <= 0) return false;
    final int offset = (total * percent.clamp(0, 100) / 100).round();
    await _state._jumpToGlobalCharOffset(offset);
    return true;
  }

  /// EPUB 没有固定页码（分页随字号 / 窗口重排），按页定位不适用。
  @override
  Future<bool> goToPage(int pageIndex) async => false;
}
