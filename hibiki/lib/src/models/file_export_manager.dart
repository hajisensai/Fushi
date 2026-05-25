import 'dart:io';

import 'package:path/path.dart' as path;

class FileExportManager {
  FileExportManager({
    required Directory exportDirectory,
    required Directory alternateExportDirectory,
  })  : _exportDirectory = exportDirectory,
        _alternateExportDirectory = alternateExportDirectory;

  final Directory _exportDirectory;
  final Directory _alternateExportDirectory;

  Directory get exportDirectory => _exportDirectory;
  Directory get alternateExportDirectory => _alternateExportDirectory;

  File getImageExportFile({bool fallback = false}) {
    final dir = fallback ? _alternateExportDirectory : _exportDirectory;
    return File(path.join(dir.path, 'exportImage.jpg'));
  }

  File getImageCompressedFile({bool fallback = false}) {
    final dir = fallback ? _alternateExportDirectory : _exportDirectory;
    return File(path.join(dir.path, 'compressedImage.jpg'));
  }

  File getAudioExportFile({bool fallback = false, String ext = 'mp3'}) {
    final dir = fallback ? _alternateExportDirectory : _exportDirectory;
    return File(path.join(dir.path, 'exportAudio.$ext'));
  }

  File getPreviewImageFile(Directory directory, int index) =>
      File(path.join(directory.path, 'previewImage$index.jpg'));

  File getAudioPreviewFile(Directory directory, {String ext = 'mp3'}) =>
      File(path.join(directory.path, 'previewAudio.$ext'));

  File getThumbnailFile() =>
      File(path.join(_exportDirectory.path, 'thumbnail.jpg'));
}
