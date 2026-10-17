import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/collection_exporter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

// Real exporter and real temporary files. Only the
// native save dialog is controlled, so each export's completion is deterministic.
class _HeldSaveDialogs extends FilePicker {
  final List<Completer<String?>> replies = <Completer<String?>>[];
  final Map<int, Completer<void>> _arrivals = <int, Completer<void>>{};

  Future<void> entered(int count) {
    if (replies.length >= count) return Future<void>.value();
    return (_arrivals[count] ??= Completer<void>()).future;
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) {
    final Completer<String?> reply = Completer<String?>();
    replies.add(reply);
    _arrivals.remove(replies.length)?.complete();
    return reply.future;
  }
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel paths = MethodChannel('plugins.flutter.io/path_provider');

  // Unit tests do not run native plugin registration. Establish a harmless
  // default before a scenario saves/restores the process-local singleton.
  setUpAll(() => FilePicker.platform = _HeldSaveDialogs());

  for (final ({String label, bool sameName, bool cancelFirst}) scenario
      in <({String label, bool sameName, bool cancelFirst})>[
        (
          label: 'control: different names',
          sameName: false,
          cancelFirst: false,
        ),
        (
          label: 'same name keeps each export content',
          sameName: true,
          cancelFirst: false,
        ),
        (
          label: 'cancel one same-name export preserves the other',
          sameName: true,
          cancelFirst: true,
        ),
      ]) {
    testWidgets(scenario.label, (WidgetTester tester) async {
      final Directory scratch = Directory.systemTemp.createTempSync(
        'fushi-round8-export-',
      );
      final Directory temporary = Directory(p.join(scratch.path, 'temporary'))
        ..createSync();
      final File firstDestination = File(p.join(scratch.path, 'first.txt'));
      final File secondDestination = File(p.join(scratch.path, 'second.txt'));
      final FilePicker previous = FilePicker.platform;
      final _HeldSaveDialogs dialogs = _HeldSaveDialogs();
      FilePicker.platform = dialogs;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        paths,
        (MethodCall _) async => temporary.path,
      );
      late BuildContext exportContext;
      String? firstContent;
      String? secondContent;
      try {
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (BuildContext context) {
                    exportContext = context;
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          final Future<void> first = saveOrShareExport(
            context: exportContext,
            content: 'first collection content',
            fileName: 'collection.txt',
            mimeType: 'text/plain',
            subject: 'first',
          );
          await dialogs.entered(1);
          final Future<void> second = saveOrShareExport(
            context: exportContext,
            content: 'second collection content',
            fileName: scenario.sameName ? 'collection.txt' : 'other.txt',
            mimeType: 'text/plain',
            subject: 'second',
          );
          await dialogs.entered(2);
          dialogs.replies[0].complete(
            scenario.cancelFirst ? null : firstDestination.path,
          );
          await first;
          dialogs.replies[1].complete(secondDestination.path);
          await second;
          firstContent = firstDestination.existsSync()
              ? firstDestination.readAsStringSync()
              : null;
          secondContent = secondDestination.existsSync()
              ? secondDestination.readAsStringSync()
              : null;
          expect(
            temporary.listSync(),
            isEmpty,
            reason: 'completed and cancelled exports clean their staging files',
          );
        });
        debugPrint(
          'round8 export ${scenario.label}: first=$firstContent '
          'second=$secondContent',
        );
      } finally {
        FilePicker.platform = previous;
        binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        scratch.deleteSync(recursive: true);
      }
      expect(
        firstContent,
        scenario.cancelFirst ? null : 'first collection content',
      );
      expect(secondContent, 'second collection content');
    }, skip: !(Platform.isWindows || Platform.isLinux || Platform.isMacOS));
  }
}
