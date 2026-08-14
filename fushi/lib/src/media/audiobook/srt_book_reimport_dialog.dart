import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/import/epub_backed_srt_book.dart';
import 'package:fushi/src/media/import/import_dialog_frame.dart';
import 'package:fushi/src/media/import/import_flow_mixin.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/import/srt_book_reimport.dart';
import 'package:fushi/src/models/app_model.dart';
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
  static const Set<String> _subtitleExtensions = <String>{
    'srt',
    'lrc',
    'vtt',
    'ass',
    'ssa',
  };

  List<String>? _audioPaths;
  String? _subtitlePath;
  String? _subtitleName;
  bool _pickerActive = false;

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
    return ImportDialogFrame(
      title: t.srt_book_reimport,
      leadingIcon: Icons.headphones_outlined,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AdaptiveSettingsSection(
            children: <Widget>[
              FushiFilePickerRow(
                title: t.srt_import_pick_audio_files,
                subtitle: _currentAudioLabel,
                icon: Icons.audio_file_outlined,
                enabled: !importing,
                onTap: _pickAudioFiles,
                actions: <Widget>[
                  FushiIconButton(
                    icon: Icons.audio_file_outlined,
                    tooltip: t.srt_import_pick_audio_files,
                    isWideTapArea: true,
                    onTap: _pickAudioFiles,
                  ),
                ],
              ),
              FushiFilePickerRow(
                title: t.srt_import_pick_subtitle_files,
                subtitle: _currentSubtitleLabel,
                icon: Icons.subtitles_outlined,
                enabled: !importing,
                onTap: _pickSubtitle,
                actions: <Widget>[
                  FushiIconButton(
                    icon: Icons.subtitles_outlined,
                    tooltip: t.srt_import_pick_subtitle_files,
                    isWideTapArea: true,
                    onTap: _pickSubtitle,
                  ),
                ],
              ),
            ],
          ),
          if (_subtitlePath != null && _bodyIsGenerated) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            Text(
              t.srt_book_reimport_subtitle_hint,
              style: tokens.type.metadata,
            ),
          ],
          if (importing) ...buildProgressSection(context, tokens),
        ],
      ),
      actions: <Widget>[
        adaptiveDialogAction(
          context: context,
          onPressed: importing ? null : () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        buildImportAction(context, onImport: _doImport),
      ],
    );
  }

  Future<void> _pickAudioFiles() async {
    if (_pickerActive || importing) return;
    _pickerActive = true;
    try {
      final AppModel appModel =
          ProviderScope.containerOf(context, listen: false).read(appProvider);
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
        _subtitlePath = path;
        _subtitleName = p.basename(path);
      });
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
