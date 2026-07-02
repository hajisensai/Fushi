import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop backup export treats a cancelled save dialog as cancellation',
      () {
    final String src =
        File('lib/src/sync/sync_settings_schema/backup.part.dart')
            .readAsStringSync()
            .replaceAll('\r\n', '\n');

    final int saveDialog =
        src.indexOf('final savePath = await FilePicker.platform.saveFile(');
    expect(saveDialog, greaterThanOrEqualTo(0),
        reason: 'Desktop backup export must use FilePicker.saveFile.');

    final int successToast = src.indexOf(
      '_showSnackBar(context, t.backup_export_success)',
      saveDialog,
    );
    expect(successToast, greaterThan(saveDialog),
        reason: 'The success toast should remain after the save branch.');

    final String desktopSaveBody = src.substring(saveDialog, successToast);
    expect(
      desktopSaveBody,
      contains('if (savePath == null) return;'),
      reason: 'If FilePicker returns null, the user cancelled or the native '
          'panel failed; the export must not show a success toast.',
    );
  });
}
