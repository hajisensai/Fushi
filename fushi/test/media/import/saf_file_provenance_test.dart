import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

import '../../helpers/test_platform_services.dart';

/// Exercise the public picker through the real codec/channel boundary, including
/// extension filtering: neither Android permission nor filtering grants a cache
/// copy permission to be retained as an original file (BUG-2265).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<T> withPicker<T>(
    WidgetTester tester,
    Object? response,
    Future<T> Function(BuildContext context, AppModel model) body,
  ) async {
    final AppModel model = AppModel(testPlatformServices());
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FushiChannels.saf, (MethodCall call) async {
      expect(call.method, anyOf('pickRealFile', 'pickRealDirectory'));
      return response;
    });
    try {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext value) {
              context = value;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return await body(context, model);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.saf, null);
      model.dispose();
    }
  }

  for (final bool real in <bool>[true, false]) {
    for (final Set<String>? extensions in <Set<String>?>[
      null,
      <String>{},
      <String>{'.DB'},
    ]) {
      testWidgets('SAF preserves isRealPath=$real with filter $extensions', (
        WidgetTester tester,
      ) async {
        // Deliberately use a neutral name: provenance must not be path guessing.
        const String path = '/storage/provider/android_english.db';
        final PickedFilePath? picked = await withPicker(
          tester,
          <String, Object>{'path': path, 'isRealPath': real},
          (BuildContext context, AppModel model) => pickRealFilePathDetailed(
            context: context,
            appModel: model,
            allowedExtensions: extensions,
          ),
        );
        expect(picked?.path, path);
        expect(picked?.isRealPath, real);
      });
    }
  }

  testWidgets('SAF cancellation stays null', (WidgetTester tester) async {
    expect(
      await withPicker(
        tester,
        null,
        (BuildContext context, AppModel model) =>
            pickRealFilePathDetailed(context: context, appModel: model),
      ),
      isNull,
    );
  });

  for (final Object malformed in <Object>[
    '/cache/saf_pick/old-contract.db',
    <String, Object>{'path': '/storage/audio.db'},
    <String, Object>{'path': '/storage/audio.db', 'isRealPath': 'true'},
    <String, Object>{'path': '', 'isRealPath': true},
    <String, Object>{'path': '   ', 'isRealPath': false},
    <String, Object>{'path': 12, 'isRealPath': false},
    <String, Object>{'isRealPath': true},
  ]) {
    testWidgets('malformed SAF result is failure: $malformed', (
      WidgetTester tester,
    ) async {
      await withPicker(tester, malformed, (
        BuildContext context,
        AppModel model,
      ) async {
        await expectLater(
          pickRealFilePathDetailed(context: context, appModel: model),
          throwsA(isA<PickedFileWithoutPathException>()),
        );
        expect(
          await pickRealFilePath(context: context, appModel: model),
          isNull,
        );
      });
    });
  }

  testWidgets('extension rejection does not accept a cache result', (
    WidgetTester tester,
  ) async {
    await withPicker(
      tester,
      <String, Object>{'path': '/provider/book.epub', 'isRealPath': false},
      (BuildContext context, AppModel model) async {
        // The filter must remain functional even if the calling page disappears
        // while the native picker is open; no toast can be shown in this case.
        await tester.pumpWidget(const SizedBox.shrink());
        expect(
          await pickRealFilePathDetailed(
            context: context,
            appModel: model,
            allowedExtensions: <String>{'db'},
          ),
          isNull,
        );
      },
    );
  });

  testWidgets('directory channel keeps its String response', (
    WidgetTester tester,
  ) async {
    expect(
      await withPicker(
        tester,
        '/storage/books',
        (BuildContext context, AppModel model) =>
            pickRealDirectoryPath(context: context, appModel: model),
      ),
      '/storage/books',
    );
  });

  test('native file channel captures provenance before copying to cache', () {
    final String source = File(
      'android/app/src/main/java/app/fushi/reader/MainActivity.java',
    ).readAsStringSync();
    final int resolve = source.indexOf(
      'String resolved = resolveSafRealPath(pickedUri, isTree);',
    );
    expect(resolve, isNonNegative);
    final String result = source.substring(
      resolve,
      source.indexOf('safResult.success(pickedResult)', resolve),
    );
    expect(result, contains('final boolean isRealPath = resolved != null;'));
    expect(
      result.indexOf('final boolean isRealPath'),
      lessThan(result.indexOf('resolved = copyUriToCache(pickedUri)')),
    );
    expect(result, contains('if (isTree || resolved == null)'));
    expect(result, contains('fileResult.put("path", resolved)'));
    expect(result, contains('fileResult.put("isRealPath", isRealPath)'));
  });
}
