import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/audiobook/audiobook_subtitle_formats.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_subtitle_book.dart'
    show downloadAudiobookshelfSubtitle;
import 'package:fushi_engine/media/import/epub_backed_srt_book.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart'
    show ImportProgressCard;
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_subtitle_dialog.dart'
    show chooseAudiobookshelfServerSubtitleFile, orderedServerSubtitles;
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_ui_helpers.dart'
    show audiobookshelfDescribeError;
import 'package:fushi/src/media/import/import_dialog_frame.dart';
import 'package:fushi/src/media/import/import_flow_mixin.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/import/srt_book_reimport.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 字幕书（`srt_books`）的**重新导入**对话框：一次同时管音频与字幕两半。
///
/// 取代原先只有音频一半的 `ReaderSrtAudioPickerDialog`。用户报「有声书没办法重新
/// 导入、导入音频没用、导不了字幕文件」的直接原因就是这里：字幕书的字幕文件在首次
/// 导入之后全仓没有任何入口能换，而 EPUB 有声书那边（[AudiobookImportDialog]）一直
/// 有「选择新字幕」——两侧不对称。
///
/// 写入一律交给 [reimportSrtBook]（唯一写入路径），本类只负责选文件与进度展示。
class SrtBookReimportDialog extends StatefulWidget {
  const SrtBookReimportDialog({
    required this.book,
    required this.db,
    required this.repo,
    super.key,
  });

  final SrtBook book;
  final FushiDatabase db;
  final SrtBookRepository repo;

  @override
  State<SrtBookReimportDialog> createState() => _SrtBookReimportDialogState();
}

class _SrtBookReimportDialogState extends State<SrtBookReimportDialog>
    with ImportFlowMixin<SrtBookReimportDialog> {
  static const Set<String> _subtitleExtensions = kAudiobookSubtitleExtensions;

  List<String>? _audioPaths;
  String? _subtitlePath;
  String? _subtitleName;
  bool _pickerActive = false;

  /// 这本书绑在 Audiobookshelf 服务器上时的绑定；只有它在时才出「从服务器选」字幕。
  RemoteAudioBinding? _serverBinding;

  /// 选中的字幕取自服务器时记下的来源（`server:<ino>`），落到绑定上；本机文件为 null。
  String? _subtitleOrigin;

  /// 「从服务器选」取到临时目录的那份字幕。重新导入会把它复制进持久目录，所以换选
  /// 别的字幕或对话框关闭（导入完 / 取消）时就删掉，不在临时目录里越堆越多。
  File? _serverDownload;

  @override
  void initState() {
    super.initState();
    unawaited(_loadServerBinding());
  }

  @override
  void dispose() {
    _discardServerDownload();
    super.dispose();
  }

  void _discardServerDownload() {
    final File? file = _serverDownload;
    _serverDownload = null;
    if (file != null) unawaited(_deleteTempFile(file));
  }

  Future<void> _loadServerBinding() async {
    final RemoteAudioBinding? binding = await RemoteAudioBindingRepository(
      widget.db,
    ).get(widget.book.uid);
    if (!mounted ||
        binding == null ||
        binding.provider != RemoteAudioBinding.providerAudiobookshelf) {
      return;
    }
    setState(() => _serverBinding = binding);
  }

  bool get _hasChanges =>
      (_audioPaths != null && _audioPaths!.isNotEmpty) || _subtitlePath != null;

  /// 这本书的正文是不是由 cue 生成的（换字幕会连带重建正文，需要提示用户）。
  /// 判据与 [reimportSrtBook] 内部的负向闸门同源：EPUB 有声书的配对行
  /// （`srtbook_epub_<bookKey>`）正文是用户自己的 EPUB，绝不重建。
  bool get _bodyIsGenerated {
    final String bookKey = widget.book.bookKey;
    if (bookKey.isEmpty) return false;
    return widget.book.uid != epubBackedSrtBookUid(bookKey);
  }

  String get _currentAudioLabel {
    final List<String>? picked = _audioPaths;
    if (picked != null && picked.isNotEmpty) {
      return t.srt_import_files_selected(n: picked.length);
    }
    final List<String>? existing = widget.book.audioPaths;
    if (existing != null && existing.isNotEmpty) {
      return t.srt_import_files_selected(n: existing.length);
    }
    final String? root = widget.book.audioRoot;
    if (root != null && root.isNotEmpty) return p.basename(root);
    return '';
  }

  String get _currentSubtitleLabel {
    final String? picked = _subtitlePath;
    if (picked != null) return _subtitleName ?? p.basename(picked);
    final String existing = widget.book.srtPath;
    return existing.isEmpty ? '' : p.basename(existing);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiTypography type = context.fushiType;
    // 导入进行中禁止返回键 / 点遮罩 / Esc 关闭（HBK-AUDIT-037，见 buildImportPopGuard）。
    return buildImportPopGuard(
      child: ImportDialogFrame(
        title: t.srt_book_reimport,
        leadingIcon: FushiIcons.audiobook,
        body: FushiEntranceScope(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              FushiStaggeredEntrance(
                index: 0,
                child: AdaptiveSettingsSection(
                  children: <Widget>[
                    FushiFilePickerRow(
                      title: t.srt_import_pick_audio_files,
                      subtitle: _currentAudioLabel,
                      icon: FushiIcons.audio,
                      enabled: !importing,
                      onTap: _pickAudioFiles,
                      actions: <Widget>[
                        FushiIconButton(
                          icon: FushiIcons.folderOpen,
                          tooltip: t.srt_import_pick_audio_files,
                          isWideTapArea: true,
                          onTap: _pickAudioFiles,
                        ),
                      ],
                    ),
                    FushiFilePickerRow(
                      title: t.srt_import_pick_subtitle_files,
                      subtitle: _currentSubtitleLabel,
                      icon: FushiIcons.subtitles,
                      enabled: !importing,
                      onTap: _pickSubtitle,
                      actions: <Widget>[
                        if (_serverBinding != null)
                          FushiIconButton(
                            icon: FushiIcons.cloudDownload,
                            tooltip: t.srt_book_reimport_subtitle_from_server,
                            isWideTapArea: true,
                            onTap: _pickServerSubtitle,
                          ),
                        FushiIconButton(
                          icon: FushiIcons.folderOpen,
                          tooltip: t.srt_import_pick_subtitle_files,
                          isWideTapArea: true,
                          onTap: _pickSubtitle,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_subtitlePath != null && _bodyIsGenerated) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                // 换字幕会连带重建正文：tertiary tonal 提示色块，不是一行灰字。
                FushiStaggeredEntrance(
                  index: 1,
                  child: FushiCard(
                    tone: FushiCardTone.tertiary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const FushiIcon(FushiIcons.info, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            t.srt_book_reimport_subtitle_hint,
                            // 色块上的字跟卡片配对前景（fushiType 自带页面前景，
                            // HBK-AUDIT-022）。
                            style: type.bodyMedium.copyWith(
                              color: fushiCardToneColors(
                                context,
                                FushiCardTone.tertiary,
                              )?.onContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (importing) ...<Widget>[
                SizedBox(height: tokens.spacing.card),
                ImportProgressCard(progress: progress, message: progressMsg),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          adaptiveDialogAction(
            context: context,
            onPressed: importing ? null : () => Navigator.pop(context),
            child: Text(t.dialog_cancel),
          ),
          buildImportAction(context, onImport: _doImport),
        ],
      ),
    );
  }

  Future<void> _pickAudioFiles() async {
    if (_pickerActive || importing) return;
    _pickerActive = true;
    try {
      final AppModel appModel = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appProvider);
      final List<String> paths = await pickRealFilePaths(
        context: context,
        appModel: appModel,
        allowedExtensions: AudiobookStorage.audioExtensionsNoDot,
      );
      if (!mounted || paths.isEmpty) return;
      paths.sort(compareAudioFilePath);
      setState(() => _audioPaths = paths);
    } finally {
      _pickerActive = false;
    }
  }

  Future<void> _pickSubtitle() async {
    if (_pickerActive || importing) return;
    _pickerActive = true;
    try {
      // 字幕当场被解析成 cue 并复制进持久目录，不以绝对路径长期引用，故用系统文件
      // 选择器（与 [BookImportDialog._pickSubtitle] 同口径，board 1360）。
      final String? path = await pickSystemFilePath(
        context: context,
        allowedExtensions: _subtitleExtensions,
      );
      if (path == null || !mounted) return;
      final String ext = p.extension(path).toLowerCase().replaceFirst('.', '');
      if (!_subtitleExtensions.contains(ext)) {
        FushiToast.show(
          msg: t.import_unsupported_file_format(ext: '.$ext'),
          severity: ToastSeverity.error,
        );
        return;
      }
      setState(() {
        _discardServerDownload();
        _subtitlePath = path;
        _subtitleName = p.basename(path);
        _subtitleOrigin = null;
      });
    } finally {
      _pickerActive = false;
    }
  }

  /// 「从服务器选」：列出服务器条目里的字幕（推荐的排第一），取回选中的那份到临时
  /// 目录，与本机选的字幕走同一条 [reimportSrtBook]，绑定上记成服务器来源。
  Future<void> _pickServerSubtitle() async {
    final RemoteAudioBinding? binding = _serverBinding;
    if (binding == null || _pickerActive || importing) return;
    final AudiobookshelfApi? api = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appProvider).audiobookshelfApiForBinding(binding);
    if (api == null) {
      FushiToast.show(
        msg: t.discovery_audiobookshelf_session_expired,
        severity: ToastSeverity.error,
      );
      return;
    }
    _pickerActive = true;
    try {
      final String? episodeId = binding.episodeId;
      // 播客请求非展开形状（与条目页同口径：展开的单集清单大、慢服务器会超时）。
      final AudiobookshelfItemDetail detail = await api.itemDetail(
        binding.itemId,
        expanded: episodeId == null,
      );
      final AudiobookshelfEpisode? episode = episodeId == null
          ? null
          : detail.episodes
                .where((AudiobookshelfEpisode e) => e.id == episodeId)
                .firstOrNull;
      final List<AudiobookshelfLibraryFile> files = orderedServerSubtitles(
        detail,
        episode: episode,
      );
      if (!mounted) return;
      if (files.isEmpty) {
        FushiToast.show(
          msg: t.srt_book_reimport_server_no_subtitles,
          severity: ToastSeverity.info,
        );
        return;
      }
      final AudiobookshelfLibraryFile? picked =
          await chooseAudiobookshelfServerSubtitleFile(
            context: context,
            files: files,
          );
      if (picked == null || !mounted) return;
      final File downloaded = await downloadAudiobookshelfSubtitle(
        api: api,
        itemId: binding.itemId,
        file: picked,
      );
      if (!mounted) {
        await _deleteTempFile(downloaded);
        return;
      }
      setState(() {
        _discardServerDownload();
        _serverDownload = downloaded;
        _subtitlePath = downloaded.path;
        _subtitleName = picked.filename;
        _subtitleOrigin = RemoteAudioBinding.subtitleOriginServer(picked.ino);
      });
    } catch (e) {
      if (mounted) {
        FushiToast.show(
          msg: t.srt_book_reimport_server_failed(
            reason: audiobookshelfDescribeError(e),
          ),
          severity: ToastSeverity.error,
        );
      }
    } finally {
      _pickerActive = false;
    }
  }

  Future<void> _doImport() async {
    if (!_hasChanges) {
      FushiToast.show(
        msg: t.srt_import_missing_input,
        severity: ToastSeverity.error,
      );
      return;
    }
    await runImport(
      logTag: 'SrtBookReimportDialog.import',
      debugMessage: (Object e) => 'SrtBookReimportDialog error: $e',
      isCancelled: (Object e) => e is SrtBookReimportEmptyCuesException,
      onCancelled: () {
        // 空 cue 不是崩溃而是「这份字幕没法用」，给具体原因、留在原地让用户换一份。
        if (mounted) {
          FushiToast.show(
            msg: t.srt_book_reimport_no_cues,
            severity: ToastSeverity.error,
          );
        }
      },
      action: () async {
        reportProgress(0, '');
        final SrtBookReimportOutcome outcome = await reimportSrtBook(
          db: widget.db,
          repo: widget.repo,
          uid: widget.book.uid,
          audioPaths: _audioPaths,
          subtitlePath: _subtitlePath,
          subtitleOrigin: _subtitleOrigin,
          onProgress: reportProgress,
          messages: SrtBookReimportMessages(
            parsing: t.import_step_parsing,
            buildingEpub: t.import_step_building_epub,
            persisting: t.import_step_persisting,
            saving: t.import_step_saving,
            done: t.import_step_done,
            copyingFile: (String name) =>
                t.import_step_copying_file(name: name),
          ),
        );
        if (mounted) {
          FushiToast.show(
            msg: t.audiobook_import_success,
            severity: ToastSeverity.success,
          );
          Navigator.pop(context, outcome);
        }
      },
    );
  }
}

/// 删临时目录里的一份文件。临时目录本身就会被系统清理，删不掉（被占用 / 已不在）
/// 不影响任何功能，所以只吞文件系统错误。
Future<void> _deleteTempFile(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // 见上：临时文件，删不掉无妨。
  }
}
