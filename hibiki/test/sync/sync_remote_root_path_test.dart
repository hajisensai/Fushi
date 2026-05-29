import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/ftp_sync_backend.dart';
import 'package:hibiki/src/sync/sftp_sync_backend.dart';

/// FTP/SFTP must store sync data under the user's login directory, never at the
/// server filesystem root. An absolute '/ttu-reader-data' fails on a normal
/// (non-chrooted) server with permission-denied at '/'.
void main() {
  test('SFTP sync root is relative to the login home, not absolute', () {
    expect(SftpSyncBackend.rootFolderName.startsWith('/'), isFalse,
        reason: 'a leading slash would target the server filesystem root');
    expect(SftpSyncBackend.rootFolderName, 'ttu-reader-data');
  });

  group('FtpSyncBackend.ftpRootPath anchors under the login home', () {
    test('chrooted home "/" reproduces the legacy path (no data move)', () {
      expect(FtpSyncBackend.ftpRootPath('/'), '/ttu-reader-data');
    });

    test('non-chrooted home nests the folder under it', () {
      expect(FtpSyncBackend.ftpRootPath('/home/user'),
          '/home/user/ttu-reader-data');
      expect(FtpSyncBackend.ftpRootPath('/home/user/'),
          '/home/user/ttu-reader-data');
    });

    test('empty/unknown home falls back to root-relative', () {
      expect(FtpSyncBackend.ftpRootPath(''), '/ttu-reader-data');
    });
  });
}
