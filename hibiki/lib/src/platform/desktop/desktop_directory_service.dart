import 'dart:io';

import 'package:hibiki_platform/hibiki_platform.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class DesktopDirectoryService implements PlatformDirectoryService {
  @override
  Future<String> getHibikiExportDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final hibikiDir = Directory(p.join(docs.path, 'Hibiki'));
    if (!hibikiDir.existsSync()) {
      hibikiDir.createSync(recursive: true);
    }
    return hibikiDir.path;
  }

  @override
  Future<List<String>> getExternalStorageDirectories() async => [];

  @override
  Future<List<String>> getDefaultPickerDirectories() async {
    // Resolve the user's real Documents/Downloads folders via the OS rather
    // than joining literal English names, which silently miss localized
    // installs (e.g. German 'Dokumente') and Linux XDG layouts (HBK-AUDIT-132).
    final result = <String>[];

    final String? documents = await _resolveDocumentsDirectory();
    if (documents != null) result.add(documents);

    final String? downloads = await _resolveDownloadsDirectory();
    if (downloads != null) result.add(downloads);

    return result.where((d) => Directory(d).existsSync()).toList();
  }

  /// Resolve the user's Documents directory. On Linux the XDG user dir is
  /// consulted first; otherwise path_provider's OS-aware lookup is used, with a
  /// home-relative English path only as a last resort (HBK-AUDIT-132).
  Future<String?> _resolveDocumentsDirectory() async {
    if (Platform.isLinux) {
      final String? xdg = Platform.environment['XDG_DOCUMENTS_DIR'];
      if (xdg != null && xdg.isNotEmpty) return xdg;
    }
    try {
      final Directory docs = await getApplicationDocumentsDirectory();
      return docs.path;
    } catch (_) {
      return _homeRelative('Documents');
    }
  }

  /// Resolve the user's Downloads directory via path_provider (OS/locale
  /// aware), consulting the Linux XDG user dir first and falling back to a
  /// home-relative English path only if both fail (HBK-AUDIT-132).
  Future<String?> _resolveDownloadsDirectory() async {
    if (Platform.isLinux) {
      final String? xdg = Platform.environment['XDG_DOWNLOAD_DIR'];
      if (xdg != null && xdg.isNotEmpty) return xdg;
    }
    try {
      final Directory? downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads.path;
    } catch (_) {
      // Fall through to the home-relative fallback below.
    }
    return _homeRelative('Downloads');
  }

  /// Last-resort fallback: join the OS home directory with [folder]. Used only
  /// when the OS-aware lookups fail.
  String? _homeRelative(String folder) {
    final String? home = Platform.isWindows
        ? Platform.environment['USERPROFILE']
        : Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return p.join(home, folder);
  }

  @override
  Future<void> excludeFromMediaScanner(String directoryPath) async {}
}
