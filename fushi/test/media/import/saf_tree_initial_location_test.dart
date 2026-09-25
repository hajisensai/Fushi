import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

import '../../helpers/test_platform_services.dart';

/// BUG-2646：安卓的目录选择器（`ACTION_OPEN_DOCUMENT_TREE`）必须带起点。
///
/// 裸 intent 让 DocumentsUI 自选落点，部分 ROM 停在「最近」——目录模式下那里空无
/// 一物、没有「使用此文件夹」按钮，用户一个目录都选不了（用户录屏：下载中心 →
/// 设置 → 下载目录 → 更改目录）。修法两段：Dart 把调用方的当前目录经通道交给原生，
/// 原生换成 `EXTRA_INITIAL_URI`（共享存储外的路径退回内部存储根目录）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String mainActivityPath =
      'android/app/src/main/java/app/fushi/reader/MainActivity.java';

  testWidgets('pickRealDirectoryPath forwards initialDirectory to native SAF', (
    WidgetTester tester,
  ) async {
    final AppModel model = AppModel(testPlatformServices());
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FushiChannels.saf, (MethodCall call) async {
      calls.add(call);
      return '/storage/emulated/0/Download/Fushi';
    });
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
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pickRealDirectoryPath(
        context: context,
        appModel: model,
        initialDirectory: '/storage/emulated/0/Download/Fushi',
      );
      await pickRealDirectoryPath(context: context, appModel: model);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.saf, null);
      model.dispose();
    }

    expect(calls.map((MethodCall c) => c.method), <String>[
      'pickRealDirectory',
      'pickRealDirectory',
    ]);
    expect(
      (calls.first.arguments as Map<Object?, Object?>)['initialDirectory'],
      '/storage/emulated/0/Download/Fushi',
    );
    // null 也要作为参数结构送达：原生据此退回内部存储根目录，而不是不设起点。
    expect(calls.last.arguments, isA<Map<Object?, Object?>>());
    expect(
      (calls.last.arguments as Map<Object?, Object?>)['initialDirectory'],
      isNull,
    );
  });

  test('every ACTION_OPEN_DOCUMENT_TREE intent gets an initial location', () {
    final String src = File(mainActivityPath).readAsStringSync();
    final RegExp treeIntent = RegExp(
      r'Intent (\w+) = new Intent\(Intent\.ACTION_OPEN_DOCUMENT_TREE\);',
    );
    final List<RegExpMatch> matches = treeIntent.allMatches(src).toList();
    expect(matches, isNotEmpty, reason: 'MainActivity 仍应有目录选择入口');
    for (final RegExpMatch m in matches) {
      final String variable = m.group(1)!;
      final int launch = src.indexOf('startActivityForResult($variable', m.end);
      expect(launch, isNonNegative, reason: '$variable 必须被启动');
      expect(
        src.substring(m.end, launch),
        contains('applyTreeInitialLocation($variable,'),
        reason: '$variable 启动前必须设起点，裸 intent 在部分 ROM 停在空的「最近」',
      );
    }
    // 入口数与起点设置数一一对应，防止新增入口漏设。
    expect(
      'applyTreeInitialLocation('.allMatches(src).length,
      matches.length + 1, // + 方法声明本身
    );
  });

  test('applyTreeInitialLocation always sets EXTRA_INITIAL_URI', () {
    final String src = File(mainActivityPath).readAsStringSync();
    final int start = src.indexOf('private void applyTreeInitialLocation(');
    expect(start, isNonNegative);
    final String body = src.substring(start, src.indexOf('\n    }\n', start));
    expect(body, contains('DocumentsContract.EXTRA_INITIAL_URI'));
    expect(body, contains('"com.android.externalstorage.documents"'));
    // 算不出共享存储 docId 时必须退回内部存储根，而不是跳过设置。
    expect(body, contains('"primary:"'));
    expect(
      src,
      contains(
          'applyTreeInitialLocation(dirIntent, call.argument("initialDirectory"))'),
      reason: 'pickRealDirectory 必须把 Dart 交来的当前目录用作起点',
    );
  });

  test('download save root picker starts from the current folder', () {
    final String src = File(
      'lib/src/pages/implementations/torrent_settings_section.dart',
    ).readAsStringSync();
    final int start = src.indexOf('Future<void> _changeDownloadFolder()');
    expect(start, isNonNegative);
    final String body =
        src.substring(start, src.indexOf('Future<', start + 10));
    expect(body, contains('initialDirectory:'));
  });
}
