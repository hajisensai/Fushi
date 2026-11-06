/// 「给这本书挂字幕」的选择：服务器条目里的字幕文件（推荐的排第一），或本机文件。
///
/// 只拼现成的组件：[showFushiChoiceDialog] 选来源，选「本机」再走系统文件选择器。
/// 返回 null = 用户取消（或选了不支持的格式，已提示）。
library;

import 'package:flutter/widgets.dart';
import 'package:fushi/src/media/audiobook/remote/audiobookshelf_stream_service.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_engine/media/audiobook/audiobook_subtitle_formats.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:path/path.dart' as p;

/// 「从本机选」的哨兵值（选项值类型是 [Object]，服务器文件用 [ServerSubtitleChoice]）。
const Object _kPickFromDevice = Object();
const Object _kNoSubtitle = Object();

/// 服务器字幕的排列：推荐的（[suggestServerSubtitle]）在最前，其余按服务器原序。
/// 流式建书的选择框与字幕书「重新导入」的「从服务器选」共用。
List<AudiobookshelfLibraryFile> orderedServerSubtitles(
  AudiobookshelfItemDetail detail, {
  AudiobookshelfEpisode? episode,
}) {
  final AudiobookshelfLibraryFile? suggested = suggestServerSubtitle(
    detail,
    episode: episode,
  )?.file;
  return <AudiobookshelfLibraryFile>[
    if (suggested != null) suggested,
    for (final AudiobookshelfLibraryFile file in detail.subtitleFiles)
      if (file.ino != suggested?.ino) file,
  ];
}

FushiChoiceOption<T> _serverFileOption<T>(
  AudiobookshelfLibraryFile file,
  T value,
) => FushiChoiceOption<T>(
  value: value,
  label: file.filename,
  subtitle: t.audiobookshelf_subtitle_on_server,
  icon: FushiIcons.subtitles,
);

/// 只在服务器字幕里选一份（字幕书「重新导入」的「从服务器选」）。[files] 由调用方
/// 按 [orderedServerSubtitles] 排好；返回 null = 取消。
Future<AudiobookshelfLibraryFile?> chooseAudiobookshelfServerSubtitleFile({
  required BuildContext context,
  required List<AudiobookshelfLibraryFile> files,
}) => showFushiChoiceDialog<AudiobookshelfLibraryFile>(
  context: context,
  title: t.audiobookshelf_subtitle_title,
  icon: FushiIcons.subtitles,
  options: <FushiChoiceOption<AudiobookshelfLibraryFile>>[
    for (final AudiobookshelfLibraryFile file in files)
      _serverFileOption<AudiobookshelfLibraryFile>(file, file),
  ],
);

Future<AudiobookshelfSubtitleChoice?> chooseAudiobookshelfSubtitle({
  required BuildContext context,
  required AudiobookshelfItemDetail detail,
  AudiobookshelfEpisode? episode,
}) async {
  final List<AudiobookshelfLibraryFile> serverFiles = orderedServerSubtitles(
    detail,
    episode: episode,
  );
  final List<FushiChoiceOption<Object>> options = <FushiChoiceOption<Object>>[
    for (final AudiobookshelfLibraryFile file in serverFiles)
      _serverFileOption<Object>(file, ServerSubtitleChoice(file)),
    FushiChoiceOption<Object>(
      value: _kPickFromDevice,
      label: t.audiobookshelf_subtitle_from_device,
      icon: FushiIcons.folderOpen,
    ),
    FushiChoiceOption<Object>(
      value: _kNoSubtitle,
      label: t.audiobookshelf_subtitle_none,
      subtitle: t.audiobookshelf_subtitle_none_hint,
      icon: FushiIcons.audiobook,
    ),
  ];
  final Object? picked = await showFushiChoiceDialog<Object>(
    context: context,
    title: t.audiobookshelf_subtitle_title,
    message: serverFiles.isEmpty
        ? '${t.audiobookshelf_subtitle_message}\n'
              '${t.audiobookshelf_subtitle_none_on_server}'
        : t.audiobookshelf_subtitle_message,
    icon: FushiIcons.subtitles,
    options: options,
  );
  if (picked == null) return null;
  if (picked is ServerSubtitleChoice) return picked;
  if (identical(picked, _kNoSubtitle)) return const NoSubtitleChoice();
  if (!context.mounted) return null;

  final String? path = await pickSystemFilePath(
    context: context,
    allowedExtensions: kAudiobookSubtitleExtensions,
  );
  if (path == null) return null;
  final String ext = p.extension(path).toLowerCase().replaceFirst('.', '');
  if (!kAudiobookSubtitleExtensions.contains(ext)) {
    FushiToast.show(
      msg: t.import_unsupported_file_format(ext: '.$ext'),
      severity: ToastSeverity.error,
    );
    return null;
  }
  return LocalSubtitleChoice(path);
}
