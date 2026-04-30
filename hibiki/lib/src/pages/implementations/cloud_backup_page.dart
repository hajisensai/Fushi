import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:intl/intl.dart' as intl;
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/cloud_backup/google_drive_backup_service.dart';

class CloudBackupPage extends BasePage {
  const CloudBackupPage({super.key});

  @override
  BasePageState<CloudBackupPage> createState() => _CloudBackupPageState();
}

class _CloudBackupPageState extends BasePageState<CloudBackupPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final int lastRunAt = appModel.cloudBackupLastRunAt;
    final String lastRunLabel = lastRunAt == 0
        ? 'Never'
        : intl.DateFormat.yMd().add_Hm().format(
              DateTime.fromMillisecondsSinceEpoch(lastRunAt),
            );

    return Scaffold(
      appBar: AppBar(title: const Text('Google Drive Backup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Automatic backup'),
            subtitle: Text('Runs at startup, at most once every 12 hours.\n'
                'Last backup: $lastRunLabel'),
            value: appModel.cloudBackupEnabled,
            onChanged: _busy
                ? null
                : (bool value) async {
                    setState(() => _busy = true);
                    try {
                      if (value) {
                        await appModel
                            .createGoogleDriveBackupService()
                            .signIn();
                      }
                      await appModel.setCloudBackupEnabled(value);
                      Fluttertoast.showToast(
                        msg: value
                            ? 'Automatic backup enabled'
                            : 'Automatic backup disabled',
                      );
                    } catch (e) {
                      Fluttertoast.showToast(
                        msg: 'Google Drive sign-in failed',
                      );
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            enabled: !_busy,
            leading: const Icon(Icons.cloud_upload),
            title: const Text('Back up now'),
            subtitle: const Text('Uploads one Hibiki backup snapshot to Drive.'),
            onTap: _backupNow,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            enabled: !_busy,
            leading: const Icon(Icons.cloud_download),
            title: const Text('Restore from Google Drive'),
            subtitle: const Text('Replaces local Hibiki data, then restarts.'),
            onTap: _restoreFromDrive,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            enabled: !_busy,
            leading: const Icon(Icons.logout),
            title: const Text('Sign out of Google Drive'),
            onTap: _signOut,
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }

  Future<void> _backupNow() async {
    setState(() => _busy = true);
    try {
      final CloudBackupUploadResult result =
          await appModel.backupToGoogleDrive();
      final String mb = (result.uploadedBytes / (1024 * 1024))
          .toStringAsFixed(1);
      Fluttertoast.showToast(msg: 'Backup uploaded ($mb MB)');
    } catch (e) {
      debugPrint('[hibiki-cloud-backup] manual backup failed: $e');
      Fluttertoast.showToast(msg: 'Google Drive backup failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreFromDrive() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Restore backup?'),
          content: const Text(
            'This replaces local Hibiki data with the latest Google Drive '
            'backup and restarts the app.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Restore'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      await appModel.restoreFromGoogleDrive();
    } catch (e) {
      debugPrint('[hibiki-cloud-backup] restore failed: $e');
      Fluttertoast.showToast(msg: 'Google Drive restore failed');
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await appModel.createGoogleDriveBackupService().signOut();
      await appModel.setCloudBackupEnabled(false);
      Fluttertoast.showToast(msg: 'Signed out');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
