import 'dart:io';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'backup_snapshot_service.dart';

class CloudBackupUploadResult {
  const CloudBackupUploadResult({
    required this.fileId,
    required this.uploadedBytes,
    required this.created,
  });

  final String fileId;
  final int uploadedBytes;
  final bool created;
}

class CloudBackupRestoreResult {
  const CloudBackupRestoreResult({
    required this.fileId,
    required this.downloadedBytes,
  });

  final String fileId;
  final int downloadedBytes;
}

class DownloadedBackupSnapshot {
  const DownloadedBackupSnapshot({
    required this.fileId,
    required this.file,
    required this.downloadedBytes,
  });

  final String fileId;
  final File file;
  final int downloadedBytes;
}

class GoogleDriveBackupService {
  GoogleDriveBackupService({
    required BackupSnapshotService snapshotService,
    GoogleSignIn? googleSignIn,
  })  : _snapshotService = snapshotService,
        _googleSignIn = googleSignIn ??
            GoogleSignIn(
              scopes: <String>[drive.DriveApi.driveAppdataScope],
            );

  static const String backupFileName = BackupSnapshotService.snapshotFileName;

  final BackupSnapshotService _snapshotService;
  final GoogleSignIn _googleSignIn;

  GoogleSignInAccount? get currentUser => _googleSignIn.currentUser;

  Future<GoogleSignInAccount?> signIn({bool interactive = true}) async {
    GoogleSignInAccount? account = await _googleSignIn.signInSilently();
    if (account == null && interactive) {
      account = await _googleSignIn.signIn();
    }
    return account;
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
  }

  Future<CloudBackupUploadResult> backupNow({
    required String appVersion,
    bool interactive = true,
  }) async {
    final http.Client client = await _authenticatedClient(
      interactive: interactive,
    );
    try {
      final drive.DriveApi api = drive.DriveApi(client);
      final File snapshot =
          await _snapshotService.createSnapshot(appVersion: appVersion);
      final drive.File? existing = await _findBackupFile(api);
      final int length = await snapshot.length();
      final drive.Media media = drive.Media(snapshot.openRead(), length);
      final drive.File metadata = drive.File()
        ..name = backupFileName
        ..modifiedTime = DateTime.now().toUtc();

      if (existing?.id != null) {
        final drive.File updated = await api.files.update(
          metadata,
          existing!.id!,
          uploadMedia: media,
          $fields: 'id',
        );
        return CloudBackupUploadResult(
          fileId: updated.id ?? existing.id!,
          uploadedBytes: length,
          created: false,
        );
      }

      metadata.parents = <String>['appDataFolder'];
      final drive.File created = await api.files.create(
        metadata,
        uploadMedia: media,
        $fields: 'id',
      );
      return CloudBackupUploadResult(
        fileId: created.id ?? '',
        uploadedBytes: length,
        created: true,
      );
    } finally {
      client.close();
    }
  }

  Future<CloudBackupRestoreResult> restoreLatest({
    bool interactive = true,
  }) async {
    final DownloadedBackupSnapshot snapshot = await downloadLatestSnapshot(
      interactive: interactive,
    );
    await _snapshotService.restoreSnapshot(snapshot.file);
    return CloudBackupRestoreResult(
      fileId: snapshot.fileId,
      downloadedBytes: snapshot.downloadedBytes,
    );
  }

  Future<DownloadedBackupSnapshot> downloadLatestSnapshot({
    bool interactive = true,
  }) async {
    final http.Client client = await _authenticatedClient(
      interactive: interactive,
    );
    try {
      final drive.DriveApi api = drive.DriveApi(client);
      final drive.File? existing = await _findBackupFile(api);
      final String? fileId = existing?.id;
      if (fileId == null) {
        throw StateError('No Google Drive backup found.');
      }

      final Object mediaResponse = await api.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      );
      final drive.Media media = mediaResponse as drive.Media;
      final File snapshot = File(
        p.join(_snapshotService.stagingDirectory.path, backupFileName),
      );
      if (!snapshot.parent.existsSync()) {
        snapshot.parent.createSync(recursive: true);
      }

      final IOSink sink = snapshot.openWrite();
      int downloaded = 0;
      try {
        await for (final List<int> chunk in media.stream) {
          downloaded += chunk.length;
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }

      return DownloadedBackupSnapshot(
        fileId: fileId,
        file: snapshot,
        downloadedBytes: downloaded,
      );
    } finally {
      client.close();
    }
  }

  Future<http.Client> _authenticatedClient({
    required bool interactive,
  }) async {
    final GoogleSignInAccount? account = await signIn(interactive: interactive);
    if (account == null) {
      throw StateError('Google sign-in was cancelled.');
    }
    final http.Client? client = await _googleSignIn.authenticatedClient();
    if (client == null) {
      throw StateError('Google Drive authentication failed.');
    }
    return client;
  }

  Future<drive.File?> _findBackupFile(drive.DriveApi api) async {
    final drive.FileList files = await api.files.list(
      spaces: 'appDataFolder',
      q: "name='$backupFileName' and trashed=false",
      orderBy: 'modifiedTime desc',
      pageSize: 1,
      $fields: 'files(id,name,modifiedTime,size)',
    );
    if (files.files == null || files.files!.isEmpty) {
      return null;
    }
    return files.files!.first;
  }
}
