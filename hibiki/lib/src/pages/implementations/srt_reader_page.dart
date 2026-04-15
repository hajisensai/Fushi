import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:hibiki/src/media/audiobook/audiobook_controller.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';
import 'package:hibiki/src/media/audiobook/srt_book_model.dart';
import 'package:hibiki/src/media/audiobook/srt_book_repository.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

/// SRT 独立有声书阅读器。
///
/// 纯 Flutter ListView：每行为一条 SRT cue，单词可点击查词，
/// 底部播放控制条，播放时自动高亮并滚动到当前句。
///
/// 使用 [Navigator.push] 打开：
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => SrtReaderPage(book: book),
/// ));
/// ```
class SrtReaderPage extends ConsumerStatefulWidget {
  const SrtReaderPage({required this.book, super.key});

  final SrtBook book;

  @override
  ConsumerState<SrtReaderPage> createState() => _SrtReaderPageState();
}

class _SrtReaderPageState extends ConsumerState<SrtReaderPage> {
  // ── 数据 ────────────────────────────────────────────────────────────────────

  List<AudioCue> _cues = [];

  // ── 音频 ────────────────────────────────────────────────────────────────────

  AudiobookPlayerController? _audioCtrl;
  bool _audioInitializing = false;

  // ── 滚动 ────────────────────────────────────────────────────────────────────

  final ItemScrollController _scrollCtrl = ItemScrollController();
  final ItemPositionsListener _positionsListener =
      ItemPositionsListener.create();

  // ── 高亮 ────────────────────────────────────────────────────────────────────

  /// 当前播放句的 sentenceIndex，-1 = 无。
  int _currentIndex = -1;

  // ── 词语 token 缓存 ──────────────────────────────────────────────────────────

  /// sentenceIndex → List of (surface form, start offset within cue.text)
  final Map<int, List<(String, int)>> _tokenCache = {};

  // ── 生命周期 ────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _audioCtrl?.removeListener(_onCueChanged);
    _audioCtrl?.dispose();
    super.dispose();
  }

  // ── 初始化 ──────────────────────────────────────────────────────────────────

  Future<void> _init() async {
    _loadCues();
    await _initAudio();
  }

  void _loadCues() {
    final appModel = ref.read(appProvider);
    final repo = SrtBookRepository(appModel.database);
    if (mounted) {
      setState(() {
        _cues = repo.cuesFor(widget.book.uid);
      });
    }
  }

  Future<void> _initAudio() async {
    if (_audioInitializing) return;
    _audioInitializing = true;

    final dir = Directory(widget.book.audioRoot);
    if (!dir.existsSync()) {
      _audioInitializing = false;
      return;
    }

    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) {
          final ext = f.path.toLowerCase();
          return ext.endsWith('.mp3') ||
              ext.endsWith('.m4a') ||
              ext.endsWith('.ogg') ||
              ext.endsWith('.aac');
        })
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    if (files.isEmpty) {
      _audioInitializing = false;
      return;
    }

    // 临时 Audiobook 供 AudiobookPlayerController 使用（只需 bookUid 字段）
    final fakeBook = Audiobook()
      ..bookUid = widget.book.uid
      ..audioRoot = widget.book.audioRoot
      ..alignmentFormat = 'srt'
      ..alignmentPath = widget.book.srtPath;

    final ctrl = AudiobookPlayerController();
    try {
      await ctrl.load(audiobook: fakeBook, audioFiles: files);
      // 挂载全部 cue（单章节策略）
      ctrl.setChapterCues(_cues);
      ctrl.addListener(_onCueChanged);

      if (mounted) {
        setState(() => _audioCtrl = ctrl);
      }
    } catch (e) {
      ctrl.dispose();
      debugPrint('SrtReaderPage: audio init error: $e');
    } finally {
      _audioInitializing = false;
    }
  }

  // ── cue 变化回调 ────────────────────────────────────────────────────────────

  void _onCueChanged() {
    final newIdx = _audioCtrl?.currentCue?.sentenceIndex ?? -1;
    if (newIdx == _currentIndex) return;
    if (mounted) {
      setState(() => _currentIndex = newIdx);
    }
    if (newIdx >= 0 && newIdx < _cues.length && _scrollCtrl.isAttached) {
      _scrollCtrl.scrollTo(
        index: newIdx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
        alignment: 0.3, // 距顶部 30%
      );
    }
  }

  // ── 词语 token 计算（懒加载 + 缓存）─────────────────────────────────────────

  List<(String, int)> _getTokens(AudioCue cue) {
    return _tokenCache.putIfAbsent(cue.sentenceIndex, () {
      final appModel = ref.read(appProvider);
      final tokens = appModel.targetLanguage.textToWords(cue.text);
      final List<(String, int)> result = [];
      int from = 0;
      for (final tok in tokens) {
        if (tok.isEmpty) continue;
        final idx = cue.text.indexOf(tok, from);
        if (idx >= 0) {
          result.add((tok, idx));
          from = idx + tok.length;
        } else {
          // 备用：token 紧跟上一个位置（避免丢词）
          result.add((tok, from));
          from += tok.length;
        }
      }
      return result;
    });
  }

  // ── 交互 ────────────────────────────────────────────────────────────────────

  /// 点击 token → 以该字符偏移作为起始，调用 Yomitan 风格的贪婪搜索。
  Future<void> _onTokenTap(String cueText, int charOffset) async {
    final appModel = ref.read(appProvider);
    final searchTerm = appModel.targetLanguage.getSearchTermFromIndex(
      text: cueText,
      index: charOffset,
    );
    if (searchTerm.trim().isEmpty) return;
    await appModel.openRecursiveDictionarySearch(
      searchTerm: searchTerm,
      killOnPop: false,
    );
  }

  /// 点击时间戳 → 跳转播放位置到该 cue。
  Future<void> _seekToCue(AudioCue cue) async {
    await _audioCtrl?.skipToCue(cue);
  }

  // ── 构建 ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.title, overflow: TextOverflow.ellipsis),
      ),
      body: Stack(
        children: [
          _buildList(),
          if (_audioCtrl != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ListenableBuilder(
                listenable: _audioCtrl!,
                builder: (_, __) => AudiobookPlayBar(controller: _audioCtrl!),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_cues.isEmpty) {
      if (_audioInitializing) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            t.srt_no_cues,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    const double barHeight = 68;
    return ScrollablePositionedList.builder(
      itemCount: _cues.length,
      itemScrollController: _scrollCtrl,
      itemPositionsListener: _positionsListener,
      padding: EdgeInsets.only(
        top: 8,
        bottom: _audioCtrl != null ? barHeight + 8 : 8,
        left: 4,
        right: 4,
      ),
      itemBuilder: (context, index) {
        final cue = _cues[index];
        return _CueTile(
          cue: cue,
          tokens: _getTokens(cue),
          isHighlighted: cue.sentenceIndex == _currentIndex,
          onTokenTap: (offset) => _onTokenTap(cue.text, offset),
          onSeekTap: () => _seekToCue(cue),
        );
      },
    );
  }
}

// ── 单条 cue 行 ───────────────────────────────────────────────────────────────

/// 单条 SRT cue 行。
///
/// - [isHighlighted] 为 true 时背景高亮；
/// - 文字以 MeCab token 为单位可点击查词（[onTokenTap]）；
/// - 左侧时间戳可点击跳转播放位置（[onSeekTap]）。
class _CueTile extends StatelessWidget {
  const _CueTile({
    required this.cue,
    required this.tokens,
    required this.isHighlighted,
    required this.onTokenTap,
    required this.onSeekTap,
  });

  final AudioCue cue;

  /// (surface, startOffset within cue.text)
  final List<(String, int)> tokens;

  final bool isHighlighted;
  final void Function(int charOffset) onTokenTap;
  final VoidCallback onSeekTap;

  static String _formatMs(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;

    final Color bg = isHighlighted
        ? colors.primaryContainer.withAlpha(180)
        : Colors.transparent;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      color: bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 时间戳（点击跳转）
            GestureDetector(
              onTap: onSeekTap,
              child: Padding(
                padding: const EdgeInsets.only(right: 8, top: 3),
                child: Text(
                  _formatMs(cue.startMs),
                  style: tt.labelSmall?.copyWith(
                    color: isHighlighted
                        ? colors.primary
                        : colors.onSurface.withAlpha(100),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            // 词语 Wrap（MeCab token 级别可点击）
            Expanded(
              child: Wrap(
                spacing: 0,
                runSpacing: 2,
                children: [
                  for (final (surface, offset) in tokens)
                    GestureDetector(
                      onTap: () => onTokenTap(offset),
                      child: Text(
                        surface,
                        style: tt.bodyMedium?.copyWith(
                          fontSize: 18,
                          height: 1.5,
                          color: isHighlighted
                              ? colors.onPrimaryContainer
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
