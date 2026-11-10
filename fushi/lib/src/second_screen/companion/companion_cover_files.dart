import 'dart:io';

/// A local cover file for the companion from what a library card already
/// knows: the user's [override] thumbnail (looked up lazily, it may touch the
/// file system), else the item's own `file://` [imageUrl]. '' when there is
/// none (or the drive is gone).
///
/// Free of the AppModel layer so library pages can use it without pulling
/// the companion into the big import cycle; [companionMediaItemCoverPath]
/// (`companion_covers.dart`) is the AppModel-side wrapper.
///
/// Probes the file system: call it only for items that are shown
/// (BUG-3756: covers may live on a network drive).
String companionCoverFilePath({
  required File? Function() override,
  required String? imageUrl,
}) {
  try {
    final File? file = override();
    if (file != null && file.existsSync()) return file.path;
    if (imageUrl != null && imageUrl.startsWith('file://')) {
      final String path = Uri.parse(imageUrl).toFilePath();
      if (File(path).existsSync()) return path;
    }
  } on FileSystemException {
    return '';
  }
  return '';
}
