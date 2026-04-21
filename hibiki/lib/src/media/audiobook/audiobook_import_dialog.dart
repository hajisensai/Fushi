import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hibiki/src/media/audiobook/ass_parser.dart';
import 'package:hibiki/src/media/audiobook/audiobook_health.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/src/media/audiobook/epub_cue_matcher.dart';
import 'package:hibiki/src/media/audiobook/epub_srt_matcher.dart';
import 'package:hibiki/src/media/audiobook/json_alignment_parser.dart';
import 'package:hibiki/src/media/audiobook/lrc_parser.dart';
import 'package:hibiki/src/media/audiobook/sasayaki_match_codec.dart';
import 'package:hibiki/src/media/audiobook/sasayaki_rematch.dart';
import 'package:hibiki/src/media/audiobook/smil_parser.dart';
import 'package:hibiki/src/media/audiobook/srt_parser.dart';
import 'package:hibiki/src/media/audiobook/ttu_idb_reader.dart';
import 'package:hibiki/src/media/audiobook/vtt_parser.dart';
import 'package:hibiki/utils.dart';

/// 有声书导入/移除对话框。
///
/// UI 沿用 [BookImportDialog] 的双图标按钮模式：每一项右侧提供
/// "选目录"和"选文件"两个按钮，可在两种音频来源模式间切换。
class AudiobookImportDialog extends StatefulWidget {
  const AudiobookImportDialog({
    required this.bookUid,
    required this.repo,
    this.ttuBookId,
    this.serverPort,
    super.key,
  });

  final String bookUid;
  final AudiobookRepository repo;

  /// ttu Ebook Reader IndexedDB primary key for this book. 当传入且对齐文件是
  /// `.srt` 时，走 Sasayaki 路径：读 ttu IDB 取章节文本 → EpubSrtMatcher 匹配
  /// → 把命中 cue 的偏移编码写回 textFragmentId。
  final int? ttuBookId;

  /// ttu 本地服务端口，读 IDB 时需要。
  final int? serverPort;

  @override
  State<AudiobookImportDialog> createState() => _AudiobookImportDialogState();
}

class _AudiobookImportDialogState extends State<AudiobookImportDialog> {
  // ── 音频来源 ── 两者互斥，最后选的那个生效 ─────────────────────────────────
  String? _audioDir;          // folder 模式
  List<String>? _audioPaths;  // files 模式

  String? _alignmentPath;
  bool _importing = false;

  int _searchWindow = EpubSrtMatcher.defaultSearchWindow;

  // ── 自动匹配 probe 缓存 ─────────────────────────────────────────────────────
  // 反复点"自动匹配"时只读一次 ttu IDB / 只 parse 一次 cues。dialog dispose 即释放。
  bool _autoProbing = false;
  List<EpubSection>? _probedSections;
  List<AudioCue>? _probedCues;
  String? _probedCuesSourcePath;

  /// 只有 srt/lrc/vtt/ass 才跑 matcher（SMIL/JSON 有硬时间码锚点，与
  /// window 无关），且必须绑定了 ttu 才有 sections 可查，否则 slider 隐藏。
  bool get _willRunMatcher {
    if (_alignmentPath == null) return false;
    if (widget.ttuBookId == null || widget.ttuBookId! <= 0) return false;
    final String ext = _alignmentPath!.split('.').last.toLowerCase();
    return SasayakiRematch.supportedFormats.contains(ext);
  }

  /// 自动匹配还要求 ttu local server 端口可用（probe 要去 IDB 拿 sections）。
  bool get _canAutoProbe => _willRunMatcher && widget.serverPort != null;

  // ── 辅助 getter ─────────────────────────────────────────────────────────────

  bool get _hasAudioSource =>
      (_audioDir != null) || (_audioPaths != null && _audioPaths!.isNotEmpty);

  String get _audioSourceLabel {
    if (_audioPaths != null && _audioPaths!.isNotEmpty) {
      return t.srt_import_files_selected(n: _audioPaths!.length);
    }
    if (_audioDir != null) return _basename(_audioDir!);
    return '';
  }

  // ── 构建 ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final Audiobook? existing = widget.repo.findByBookUid(widget.bookUid);
    debugPrint('[hibiki-audiobook] dialog build bookUid.len=${widget.bookUid.length} '
        'hash=${widget.bookUid.hashCode} existing=${existing != null}');

    return AlertDialog(
      title: Text(
        existing != null ? t.audiobook_attached : t.audiobook_import,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: existing != null
            ? _buildAttachedView(existing)
            : SingleChildScrollView(child: _buildImportForm()),
      ),
      actions: existing != null
          ? [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t.dialog_close),
              ),
              _destructiveFilledButton(
                context: context,
                label: t.audiobook_remove,
                onPressed: () => _removeAudiobook(existing),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t.dialog_cancel),
              ),
              FilledButton(
                onPressed: _importing ? null : _doImport,
                child: Text(t.dialog_import),
              ),
            ],
    );
  }

  Widget _buildAttachedView(Audiobook ab) {
    final String audioLabel = (ab.audioPaths != null && ab.audioPaths!.isNotEmpty)
        ? t.srt_import_files_selected(n: ab.audioPaths!.length)
        : (ab.audioRoot ?? '');
    final AudiobookHealth health = widget.repo.resolveHealth(ab);
    final Widget? healthRow = _buildHealthRow(health);
    final bool canReMatch = _canReMatch(ab, health);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoRow(
          (ab.audioPaths != null && ab.audioPaths!.isNotEmpty)
              ? Icons.audio_file
              : Icons.folder_open,
          audioLabel,
        ),
        const SizedBox(height: 8),
        _infoRow(Icons.align_horizontal_left, ab.alignmentPath),
        if (healthRow != null) ...[
          const SizedBox(height: 8),
          healthRow,
        ],
        if (canReMatch) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _importing ? null : () => _openReMatchSheet(ab),
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('调整搜索窗口重新匹配'),
            ),
          ),
        ],
      ],
    );
  }

  /// 只有挂了 ttu book 且 alignmentFormat 属于 matcher 管线（srt/lrc/vtt/ass）
  /// 才显示重跑入口。SMIL/JSON 走信任文件锚点，与 searchWindow 无关。
  /// unrun 状态也允许重跑 — 历史脏记录的书借此给它跑一次。
  bool _canReMatch(Audiobook ab, AudiobookHealth health) {
    if (widget.ttuBookId == null || widget.ttuBookId! <= 0) return false;
    if (widget.serverPort == null) return false;
    if (!SasayakiRematch.isEligible(ab)) return false;
    switch (health.kind) {
      case HealthKind.partial:
      case HealthKind.failed:
      case HealthKind.unrun:
      case HealthKind.ok: // 让用户也能收紧窗口搏一个更高的匹配率
        return true;
      case HealthKind.running:
      case HealthKind.notApplicable:
        return false;
    }
  }

  /// 已附加有声书时展示匹配状态。notApplicable / unrun → 不渲染（无信息可看）。
  /// reason 来自 matcher（如 "123/140 cues matched"），直接展示给用户。
  Widget? _buildHealthRow(AudiobookHealth health) {
    IconData icon;
    Color color;
    String label;
    // pct 为 null 时多半是历史脏记录（见 AudiobookHealth.fromAudiobook 的 clamp
    // 注释）——显示 "?" 而非 0%，避免用绿色对勾配一个假的 0%。
    final String pctStr = health.ratePct?.toString() ?? '?';
    final String? reason = health.reason;
    final String tail = (reason == null || reason.isEmpty) ? '' : ' · $reason';
    switch (health.kind) {
      case HealthKind.ok:
        icon = Icons.check_circle;
        color = Colors.green;
        label = 'Sasayaki $pctStr%$tail';
      case HealthKind.partial:
        icon = Icons.warning_amber;
        color = Colors.amber;
        label = 'Sasayaki $pctStr%$tail';
      case HealthKind.failed:
        icon = Icons.error_outline;
        color = Colors.red;
        label = 'Sasayaki $pctStr%$tail';
      case HealthKind.running:
      case HealthKind.unrun:
      case HealthKind.notApplicable:
        return null;
    }
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: color),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _infoRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 12),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ),
      ],
    );
  }

  Widget _buildImportForm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _audioSourceRow(),
        const SizedBox(height: 12),
        _alignmentRow(),
        if (_willRunMatcher) ...[
          const SizedBox(height: 12),
          SasayakiWindowSlider(
            value: _searchWindow,
            onChanged: (int v) => setState(() => _searchWindow = v),
            onAutoTap: _canAutoProbe ? _handleAutoProbe : null,
            autoBusy: _autoProbing,
          ),
        ],
        if (_importing) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
      ],
    );
  }

  /// 音频来源行：标签 + [选目录] [选文件] 两个按钮。
  Widget _audioSourceRow() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _audioPaths != null
                    ? t.srt_import_pick_audio_files
                    : t.srt_import_pick_audio_dir,
                style: const TextStyle(fontSize: 13),
              ),
              if (_hasAudioSource)
                Text(
                  _audioSourceLabel,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.folder_open, size: 20),
          tooltip: t.srt_import_pick_audio_dir,
          onPressed: _pickAudioDir,
        ),
        IconButton(
          icon: const Icon(Icons.audio_file, size: 20),
          tooltip: t.srt_import_pick_audio_files,
          onPressed: _pickAudioFiles,
        ),
      ],
    );
  }

  /// 对齐文件行：标签 + [选文件] 按钮。
  Widget _alignmentRow() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.audiobook_pick_alignment,
                style: const TextStyle(fontSize: 13),
              ),
              if (_alignmentPath != null)
                Text(
                  _basename(_alignmentPath!),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.align_horizontal_left, size: 20),
          tooltip: t.audiobook_pick_alignment,
          onPressed: _pickAlignment,
        ),
      ],
    );
  }

  // ── 文件/目录选择 ────────────────────────────────────────────────────────────

  Future<void> _pickAudioDir() async {
    final String? dir = await FilePicker.platform.getDirectoryPath();
    if (dir != null && mounted) {
      setState(() {
        _audioDir = dir;
        _audioPaths = null;
      });
    }
  }

  Future<void> _pickAudioFiles() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
    );
    if (result == null || !mounted) return;

    final List<String> paths = result.files
        .map((f) => f.path)
        .whereType<String>()
        .toList()
      ..sort();

    if (paths.isNotEmpty) {
      setState(() {
        _audioPaths = paths;
        _audioDir = null;
      });
    }
  }

  Future<void> _pickAlignment() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['smil', 'json', 'srt', 'lrc', 'vtt', 'ass'],
    );
    final String? path = result?.files.single.path;
    if (path != null && mounted) {
      setState(() {
        _alignmentPath = path;
        // 换了 alignment 文件 → cue 可能完全不同，清掉 probe cue 缓存。
        // sections 来源只与 ttuBookId 相关，不清。
        _probedCues = null;
        _probedCuesSourcePath = null;
      });
    }
  }

  /// 「自动匹配」按钮：probe 当前 alignment 对本书 ttu sections 在多档 window
  /// 下的命中率，挑最高的一档回写到 slider。cues / sections 缓存避免同一次
  /// 对话反复点击时重复 IO。
  Future<void> _handleAutoProbe() async {
    if (!_canAutoProbe || _alignmentPath == null) return;
    setState(() => _autoProbing = true);
    try {
      _probedSections ??= await _loadSectionsForProbe();
      if (_probedCues == null || _probedCuesSourcePath != _alignmentPath) {
        _probedCues = await _parseCuesForProbe();
        _probedCuesSourcePath = _alignmentPath;
      }
      final int? best = await SasayakiRematch.runAutoProbe(
        sections: _probedSections ?? const <EpubSection>[],
        cues: _probedCues ?? const <AudioCue>[],
      );
      if (best != null && mounted) {
        setState(() => _searchWindow = best);
      }
    } finally {
      if (mounted) setState(() => _autoProbing = false);
    }
  }

  Future<List<EpubSection>> _loadSectionsForProbe() async {
    if (widget.ttuBookId == null ||
        widget.ttuBookId! <= 0 ||
        widget.serverPort == null) {
      return const <EpubSection>[];
    }
    try {
      final TtuBookRecord rec = await TtuIdbReader.readBookRecord(
        ttuBookId: widget.ttuBookId!,
        serverPort: widget.serverPort!,
      );
      return rec.sections;
    } catch (e) {
      debugPrint('[hibiki-audiobook] probe loadSections failed: $e');
      return const <EpubSection>[];
    }
  }

  /// 只 parse 不落库 —— 导入尚未 commit，不能污染 Isar。正式导入走 _parseCues。
  Future<List<AudioCue>> _parseCuesForProbe() async {
    final String? p = _alignmentPath;
    if (p == null) return const <AudioCue>[];
    final File f = File(p);
    final String ext = p.split('.').last.toLowerCase();
    try {
      switch (ext) {
        case 'srt':
          return await SrtParser.parse(srtFile: f, bookUid: widget.bookUid);
        case 'lrc':
          return await LrcParser.parse(lrcFile: f, bookUid: widget.bookUid);
        case 'vtt':
          return await VttParser.parse(vttFile: f, bookUid: widget.bookUid);
        case 'ass':
          return await AssParser.parse(assFile: f, bookUid: widget.bookUid);
        default:
          return const <AudioCue>[];
      }
    } catch (e) {
      debugPrint('[hibiki-audiobook] probe parseCues failed: $e');
      return const <AudioCue>[];
    }
  }

  // ── 导入 ─────────────────────────────────────────────────────────────────────

  Future<void> _doImport() async {
    if (!_hasAudioSource || _alignmentPath == null) {
      Fluttertoast.showToast(msg: t.audiobook_import_error);
      return;
    }

    debugPrint('[hibiki-audiobook] doImport bookUid.len=${widget.bookUid.length} '
        'hash=${widget.bookUid.hashCode} uid=${widget.bookUid}');
    setState(() => _importing = true);

    try {
      final String ext =
          _alignmentPath!.split('.').last.toLowerCase();
      const Set<String> cueFormats = {'smil', 'srt', 'lrc', 'vtt', 'ass'};
      final String format = cueFormats.contains(ext) ? ext : 'json';

      // 先跑 parse + matcher（含 saveCues）拿到 health；此时 Audiobook 还
      // 没写入。然后一次性带全字段 saveAudiobook —— **不能两次 put**，否则
      // Isar 会把带长 CJK bookUid 的记录写坏（FormatException offset 43）。
      // 见 `updateHealth readback THREW`。
      final AudiobookHealth health = await _parseCues(format);

      final Audiobook audiobook = Audiobook()
        ..bookUid = widget.bookUid
        ..alignmentFormat = format
        ..alignmentPath = _alignmentPath!;

      if (_audioPaths != null && _audioPaths!.isNotEmpty) {
        audiobook.audioPaths = _audioPaths;
      } else {
        audiobook.audioRoot = _audioDir;
      }

      health.packInto(audiobook);
      await widget.repo.saveAudiobook(audiobook);
      await widget.repo.updateHealthOverlay(
        bookUid: widget.bookUid,
        health: health,
      );

      if (mounted) {
        final String? tail = _summarizeHealth(health);
        final String msg = tail == null
            ? t.audiobook_import_success
            : '${t.audiobook_import_success} · $tail';
        Fluttertoast.showToast(msg: msg);
        Navigator.pop(context, true); // true = reload player
      }
    } catch (e) {
      debugPrint('AudiobookImportDialog import error: $e');
      if (mounted) {
        Fluttertoast.showToast(msg: t.audiobook_import_error);
      }
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  /// 已附加书的重跑匹配入口：委托给 [SasayakiRematch.promptAndRun]，跑完
  /// health 走 Hive overlay（不 put Audiobook，避免二次 put 把 matchRatePct
  /// 字节写坏）。
  Future<void> _openReMatchSheet(Audiobook ab) async {
    final int? ttuId = widget.ttuBookId;
    final int? port = widget.serverPort;
    if (ttuId == null || ttuId <= 0 || port == null) {
      Fluttertoast.showToast(msg: '本书未绑定 ttu，无法重跑匹配');
      return;
    }
    await SasayakiRematch.promptAndRun(
      context: context,
      ab: ab,
      repo: widget.repo,
      ttuBookId: ttuId,
      serverPort: port,
      onRunningChanged: (bool running) {
        if (mounted) setState(() => _importing = running);
      },
    );
    // 跑完无论成败都刷一次，让 healthRow 重新读 overlay。
    if (mounted) setState(() {});
  }

  /// 对 SRT/LRC/VTT/ASS 四格式：若本书已挂 ttu，跑 [EpubCueMatcher] 把命中
  /// cue 的 section/charStart/charEnd 编码写回 [AudioCue.textFragmentId]。
  /// 失败不中断导入（cues 仍按原样落库，少的只是跨章定位能力）。
  ///
  /// 返回值是本次匹配的健康度：matcher 跑起来 → fromRatePct；没 ttu 绑定 →
  /// notApplicable；reader 失败 / cues 为空 → failed。调用方据此写回
  /// [Audiobook.healthKindRaw] 等字段。
  Future<AudiobookHealth> _matchCuesToTtu(List<AudioCue> cues) async {
    final int? ttuId = widget.ttuBookId;
    final int? port = widget.serverPort;
    if (ttuId == null || ttuId <= 0 || port == null) {
      return AudiobookHealth.notApplicable(
        reason: 'no ttu book bound — subtitle playback works, but no '
            'cross-chapter highlight',
      );
    }
    if (cues.isEmpty) {
      return AudiobookHealth.failed(reason: 'parser returned 0 cues');
    }
    try {
      final TtuBookRecord rec = await TtuIdbReader.readBookRecord(
        ttuBookId: ttuId,
        serverPort: port,
      );
      final List<EpubSection> sections = rec.sections;
      if (sections.isEmpty) {
        return AudiobookHealth.failed(
          reason: 'ttu IDB record had 0 sections',
        );
      }
      // 匹配器放 isolate 跑，主线程不能被大书的 bigram 扫描挤出 ANR。
      final MatchResult result = await EpubCueMatcher.matchInIsolate(
        sections: sections,
        cues: cues,
        searchWindow: _searchWindow,
      );
      SasayakiMatchCodec.applyToCues(cues: cues, result: result);
      final int pct = (result.matchRate * 100).round();
      return AudiobookHealth.fromRatePct(
        ratePct: pct,
        reason: '${result.matchedCues}/${result.totalCues} cues matched '
            '(window=$_searchWindow)',
      );
    } catch (e) {
      debugPrint('EpubCueMatcher failed: $e');
      return AudiobookHealth.failed(reason: 'matcher threw: $e');
    }
  }

  /// 返回本次导入的健康度。所有格式都要给出一个 [AudiobookHealth]，调用方
  /// 会写回 Audiobook 记录，书卡上的角标据此展示。
  Future<AudiobookHealth> _parseCues(String format) async {
    final File alignFile = File(_alignmentPath!);

    // SRT / LRC / VTT / ASS：都走"单章节 defaultChapter"路径，都会尝试
    // matcher（前提是绑定了 ttu 书）。
    if (format == 'srt') {
      final List<AudioCue> cues = await SrtParser.parse(
        srtFile: alignFile,
        bookUid: widget.bookUid,
      );
      final AudiobookHealth health = await _matchCuesToTtu(cues);
      await widget.repo.saveCues(
        bookUid: widget.bookUid,
        chapterHref: SrtParser.defaultChapter,
        cues: cues,
      );
      return health;
    } else if (format == 'lrc') {
      final List<AudioCue> cues = await LrcParser.parse(
        lrcFile: alignFile,
        bookUid: widget.bookUid,
      );
      final AudiobookHealth health = await _matchCuesToTtu(cues);
      await widget.repo.saveCues(
        bookUid: widget.bookUid,
        chapterHref: LrcParser.defaultChapter,
        cues: cues,
      );
      return health;
    } else if (format == 'vtt') {
      final List<AudioCue> cues = await VttParser.parse(
        vttFile: alignFile,
        bookUid: widget.bookUid,
      );
      final AudiobookHealth health = await _matchCuesToTtu(cues);
      await widget.repo.saveCues(
        bookUid: widget.bookUid,
        chapterHref: VttParser.defaultChapter,
        cues: cues,
      );
      return health;
    } else if (format == 'ass') {
      final List<AudioCue> cues = await AssParser.parse(
        assFile: alignFile,
        bookUid: widget.bookUid,
      );
      final AudiobookHealth health = await _matchCuesToTtu(cues);
      await widget.repo.saveCues(
        bookUid: widget.bookUid,
        chapterHref: AssParser.defaultChapter,
        cues: cues,
      );
      return health;
    } else if (format == 'json') {
      final List<AudioCue> allCues = await JsonAlignmentParser.parse(
        jsonFile: alignFile,
        bookUid: widget.bookUid,
      );
      // 按章节批量存入 Isar
      final Map<String, List<AudioCue>> byChapter = {};
      for (final AudioCue c in allCues) {
        byChapter.putIfAbsent(c.chapterHref, () => []).add(c);
      }
      for (final MapEntry<String, List<AudioCue>> entry
          in byChapter.entries) {
        await widget.repo.saveCues(
          bookUid: widget.bookUid,
          chapterHref: entry.key,
          cues: entry.value,
        );
      }
      return _healthFromFragmentIntegrity(
        allCues,
        formatLabel: 'json',
      );
    } else {
      // SMIL：单文件对应单章节，文件名（去扩展）推断 chapterHref
      final String fileName = _alignmentPath!
          .split(Platform.pathSeparator)
          .last;
      final String chapterHref =
          fileName.replaceAll(RegExp(r'\.smil$', caseSensitive: false), '.xhtml');

      final List<AudioCue> cues = await SmilParser.parse(
        smilFile: alignFile,
        bookUid: widget.bookUid,
        chapterHref: chapterHref,
      );
      await widget.repo.saveCues(
        bookUid: widget.bookUid,
        chapterHref: chapterHref,
        cues: cues,
      );
      return _healthFromFragmentIntegrity(cues, formatLabel: 'smil');
    }
  }

  /// SMIL/JSON 的静态健康度：基于 cue 自带的 textFragmentId 完整度。
  ///
  /// SMIL fragment 形如 `#sN`，JSON 是 CSS selector。非空即视为"有定位能力"。
  /// PR8 落地后 JSON 还会追加一次 DOM 命中率复核，此处先给兜底值。
  AudiobookHealth _healthFromFragmentIntegrity(
    List<AudioCue> cues, {
    required String formatLabel,
  }) {
    if (cues.isEmpty) {
      return AudiobookHealth.failed(
        reason: '$formatLabel parser returned 0 cues',
      );
    }
    int intact = 0;
    for (final AudioCue c in cues) {
      if (c.textFragmentId.isNotEmpty) {
        intact++;
      }
    }
    final int pct = (intact * 100 / cues.length).round();
    return AudiobookHealth.fromRatePct(
      ratePct: pct,
      reason: '$intact/${cues.length} cues have fragment id',
    );
  }

  /// 把 [AudiobookHealth] 压成一段 toast 尾巴；notApplicable/unrun 返回 null
  /// 省掉冗余提示。
  String? _summarizeHealth(AudiobookHealth h) {
    switch (h.kind) {
      case HealthKind.ok:
      case HealthKind.partial:
      case HealthKind.failed:
        final int p = h.ratePct ?? 0;
        return 'match $p%';
      case HealthKind.notApplicable:
      case HealthKind.unrun:
      case HealthKind.running:
        return null;
    }
  }

  Future<void> _removeAudiobook(Audiobook ab) async {
    debugPrint('AudiobookImportDialog: remove tapped for ${widget.bookUid}');
    final NavigatorState outerNavigator =
        Navigator.of(context, rootNavigator: true);

    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(t.audiobook_remove_confirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.dialog_cancel),
          ),
          _destructiveFilledButton(
            context: ctx,
            label: t.audiobook_remove,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    debugPrint('AudiobookImportDialog: confirm=$confirm');
    if (confirm != true) return;

    try {
      await widget.repo.deleteAudiobook(widget.bookUid);
      debugPrint('AudiobookImportDialog: deleteAudiobook done');
    } catch (e, st) {
      debugPrint('AudiobookImportDialog: deleteAudiobook failed: $e\n$st');
      if (mounted) {
        Fluttertoast.showToast(msg: t.audiobook_import_error);
      }
      return;
    }

    if (mounted) {
      outerNavigator.pop(false); // false = no audiobook
    }
  }

  /// 破坏性操作统一样式：FilledButton + errorContainer。把 `Navigator.pop`
  /// 的 ctx 通过参数传进来，避免子对话框里复用父 widget 的 context。
  Widget _destructiveFilledButton({
    required BuildContext context,
    required String label,
    required VoidCallback onPressed,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: cs.errorContainer,
        foregroundColor: cs.onErrorContainer,
      ),
      child: Text(label),
    );
  }

  String _basename(String path) =>
      path.split(Platform.pathSeparator).last;
}
