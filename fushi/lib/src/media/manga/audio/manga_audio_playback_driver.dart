/// 漫画有声成品的句序驱动：由 `AudiobookSession` 的位置流推进，读到哪句框哪几块、
/// 自动翻页、用户翻页后重定位、纯听时跳过页时间。
///
/// 与现场合成（`MangaReadAloudController`）的分工：那边自己决定「下一句」并逐句合成，
/// 这边的「当前句」完全由播放位置决定（[MangaAudioPlaybackPlan.itemIndexAt]），显示与
/// 「自己翻页 vs 用户翻页」判定两边共用 [MangaSentenceFollower]。
///
/// 生命周期跟会话走（[AudiobookSessionCompanion]），不跟阅读器走：阅读器离开后会话在
/// 后台继续播，纯听形态下仍要跳过页停留 / `lead` / 页尾补静音，所以本对象由会话持有，
/// 阅读器只 [attachHost] / [detachHost]。没有宿主或阅读器不可见（判据复用
/// `readerVisibleForLifecycleState`）= 纯听；宿主在且可见 = 边看边听。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_timeline.dart';

import 'package:fushi/src/media/audiobook/audiobook_session.dart'
    show AudiobookSessionCompanion;
import 'package:fushi/src/media/manga/audio/manga_audio_playback_plan.dart';
import 'package:fushi/src/media/manga/reader/manga_read_aloud_controller.dart'
    show MangaReadAloudHost;
import 'package:fushi/src/media/manga/reader/manga_sentence_follow.dart';

/// 驱动看到的播放器（生产 = `AudiobookPlayerController` 的适配，测试 = 假播放器）。
/// 位置一律是播放列表的全书毫秒（= 边看边听时间表的毫秒）。
abstract interface class MangaAudioPlayerPort implements Listenable {
  int get positionMs;
  bool get isPlaying;
  double get speed;

  /// 音量（0.0–2.0，1.0 = 100%）。
  double get volume;
  Future<void> play();
  Future<void> pause();
  Future<void> seekMs(int ms);
  Future<void> setSpeed(double speed);

  /// 改音量（生产端按书持久化，与有声书同一个按书音量）。
  Future<void> setVolume(double volume);
}

class MangaAudioPlaybackDriver extends ChangeNotifier
    implements AudiobookSessionCompanion {
  MangaAudioPlaybackDriver({
    required this.bookKey,
    required this.plan,
    required MangaAudioPlayerPort player,
  }) : _player = player {
    _player.addListener(_onPlayer);
  }

  final String bookKey;
  final MangaAudioPlaybackPlan plan;
  final MangaAudioPlayerPort _player;

  MangaReadAloudHost? _host;
  MangaSentenceFollower? _follower;
  bool _readerVisible = false;
  bool _followPage = true;
  bool _disposed = false;

  /// 上次处理过的条目（换条目才重新显示）。
  int _item = -1;

  /// 纯听形态下已经为它发过跳转的条目（跳转在途时位置流还会报旧位置，不重复跳）。
  int _skippedFrom = -1;

  /// 在途的显式跳转（翻页重定位 / 上下句 / 拖进度）的目标毫秒，落地后为 null。
  ///
  /// 成品音频每句一个文件，跳转几乎都跨文件：播放器要换源，落地前它仍按旧文件报位置
  /// 并继续往下播。这期间若照常按位置流显示，旧位置一跨进下一句就 `show(旧页)`，把
  /// 用户刚翻走的阅读器拉回去，落地后再翻过来（BUG-4906）。所以在途期间只刷新播放条，
  /// 不显示、不翻页、不做纯听跳过；位置先一步落到目标条目上也算落地。
  int? _seekTarget;

  /// 每次显式跳转 +1：先发的跳转晚完成时不能清掉后发的那次在途标记。
  int _seekGeneration = 0;

  MangaRenderManifest get manifest => plan.manifest;
  MangaAudioPlayerPort get player => _player;

  /// 当前播放形态：宿主在场且可见才是边看边听。
  MangaPlaybackMode get mode => _host != null && _readerVisible
      ? MangaPlaybackMode.watchAndListen
      : MangaPlaybackMode.listenOnly;

  bool get followPage => _followPage;

  /// 会话停止时随之释放；释放后宿主不要再调它。
  bool get isDisposed => _disposed;
  bool get hasHost => _host != null;
  bool get isPlaying => _player.isPlaying;

  /// 播放条显示的位置：跳转在途时显示目标（播放器还在报旧位置）。
  int get positionMs => _seekTarget ?? _player.positionMs;
  int get totalMs => plan.totalMs;
  double get speed => _player.speed;
  double get volume => _player.volume;

  /// 正在播（或停在）的条目。
  MangaAudioItem? get currentItem =>
      _item >= 0 && _item < plan.items.length ? plan.items[_item] : null;

  /// 正在播的句子；在静音条目里为 null。
  MangaRenderedLine? get currentLine {
    final MangaAudioItem? item = currentItem;
    return item == null || !item.isLine ? null : manifest.lines[item.lineIndex];
  }

  /// 正在播的页（页段语义）。
  int get currentPage => currentItem?.page ?? plan.pageAt(positionMs);

  // ── 阅读器接入 ──────────────────────────────────────────────────────

  /// 阅读器接入：之后按位置流高亮 / 翻页。[visible] = 阅读器此刻可见。
  void attachHost(MangaReadAloudHost host, {required bool visible}) {
    if (_disposed) return;
    _host = host;
    _follower = MangaSentenceFollower(host);
    _readerVisible = visible;
    _item = -1;
    _sync();
  }

  /// 阅读器离开（会话照常在后台播，转纯听）。只清本宿主。
  void detachHost(MangaReadAloudHost host) {
    if (!identical(_host, host)) return;
    _follower?.interrupt();
    _host = null;
    _follower = null;
    _sync();
  }

  /// 阅读器可见性变化（App 生命周期）：不暂停，只切播放形态；回到前台重新显示当前句。
  void setReaderVisible(bool visible) {
    if (_disposed || _readerVisible == visible) return;
    _readerVisible = visible;
    if (visible) _item = -1;
    _sync();
  }

  /// 「跟随翻页」开关：关掉后不再自动翻页，用户翻页时音频也不动（设计 §3）。
  void setFollowPage(bool value) {
    if (_followPage == value) return;
    _followPage = value;
    _item = -1;
    _sync();
  }

  /// 阅读器页变化（自己翻的和用户翻的都会来）：用户翻到别的 spread 时跳到该页页段
  /// 起点继续播（播放 / 暂停状态不变）；关掉跟随时不动音频。
  void onPageChanged(int page) {
    final MangaSentenceFollower? follower = _follower;
    if (_disposed || follower == null) return;
    if (follower.isOwnPageChange(page)) return;
    follower.interrupt();
    follower.acceptPage(page);
    if (!_followPage) {
      // 不跟随：只更新高亮（新屏上有没有正在读的句子）。
      _item = -1;
      _sync();
      return;
    }
    if (page < 0 || page >= manifest.pageCount) return;
    unawaited(_seek(plan.pageStartMs(page)));
  }

  // ── 播放控制（播放条 / 快捷键） ─────────────────────────────────────

  Future<void> togglePlayPause() =>
      _player.isPlaying ? _player.pause() : _player.play();

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();

  Future<void> next() async {
    // 从 [positionMs] 算：连按时第二下接着上一下在途的目标走。
    final int? target = plan.nextLineStartMs(positionMs);
    if (target != null) await _seek(target);
  }

  Future<void> previous() => _seek(plan.previousLineStartMs(positionMs));

  /// 拖进度条。
  Future<void> seekTo(int ms) => _seek(ms.clamp(0, plan.totalMs));

  /// 从第 [lineIndex] 句句首接着播（查词后从句首重播，BUG-4909）；为 null 时从当前句
  /// 句首——停在句间停顿 / 页停留里就是本页刚读过的那句，本页还没读到句子则原地播，
  /// 不为「重播」把读者拉回上一页。
  Future<void> playFromLine(int? lineIndex) async {
    final int? target = lineIndex ?? _currentLineOnPage();
    if (target != null && target >= 0 && target < manifest.lines.length) {
      await _seek(plan.lineStartMs(target));
    }
    if (_disposed) return;
    await _player.play();
  }

  /// 当前页上、[positionMs] 处或之前最近的一句。
  int? _currentLineOnPage() {
    final int from = plan.itemIndexAt(positionMs);
    if (from < 0) return null;
    final int page = plan.items[from].page;
    for (int i = from; i >= 0; i--) {
      final MangaAudioItem item = plan.items[i];
      if (item.page != page) return null;
      if (item.isLine) return item.lineIndex;
    }
    return null;
  }

  Future<void> setSpeed(double value) async {
    await _player.setSpeed(value);
    if (!_disposed) notifyListeners();
  }

  Future<void> setVolume(double value) async {
    await _player.setVolume(value);
    if (!_disposed) notifyListeners();
  }

  @override
  bool skipLine(int delta) {
    unawaited(delta > 0 ? next() : previous());
    return true;
  }

  Future<void> _seek(int ms) async {
    _skippedFrom = -1;
    final int generation = ++_seekGeneration;
    _seekTarget = ms;
    try {
      await _player.seekMs(ms);
    } finally {
      if (generation == _seekGeneration) _seekTarget = null;
    }
    _sync();
  }

  // ── 位置流 ──────────────────────────────────────────────────────────

  void _onPlayer() => _sync();

  void _sync() {
    if (_disposed) return;
    final int pos = _player.positionMs;
    final int index = plan.itemIndexAt(pos);
    if (index < 0) return;
    final int? seeking = _seekTarget;
    if (seeking != null) {
      if (index != plan.itemIndexAt(seeking)) {
        // 跳转在途、播放器还在报旧位置（见 [_seekTarget]）：只刷新播放条。
        notifyListeners();
        return;
      }
      _seekTarget = null;
    }
    if (mode == MangaPlaybackMode.listenOnly && _player.isPlaying) {
      final int? target = plan.listenOnlySkipTarget(index);
      if (target != null) {
        if (_skippedFrom != index) {
          _skippedFrom = index;
          unawaited(_player.seekMs(target));
        }
        return;
      }
    }
    if (index == _item) {
      notifyListeners();
      return;
    }
    _item = index;
    _skippedFrom = -1;
    _show(plan.items[index]);
    notifyListeners();
  }

  /// 第 [index] 个条目上要框的句子（[MangaRenderManifest.lines] 下标），口径见
  /// [MangaAudioPlaybackPlan.currentLineItemIndex]（与「上一句」的参照句同源）。
  int? _displayLineAt(int index) {
    final int? item = plan.currentLineItemIndex(index);
    return item == null ? null : plan.items[item].lineIndex;
  }

  void _show(MangaAudioItem item) {
    final MangaReadAloudHost? host = _host;
    final MangaSentenceFollower? follower = _follower;
    if (host == null || follower == null) return;
    final int? line = _displayLineAt(_item);
    final List<int> blocks = line == null
        ? const <int>[]
        : manifest.lines[line].blocks;
    if (item.isLine) host.markStudyActivity();
    if (_followPage && _readerVisible) {
      unawaited(follower.show(item.page, blocks));
    } else {
      unawaited(follower.highlightInPlace(item.page, blocks));
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _player.removeListener(_onPlayer);
    final MangaReadAloudHost? host = _host;
    _host = null;
    _follower = null;
    if (host != null) unawaited(host.clearHighlight());
    super.dispose();
  }
}
