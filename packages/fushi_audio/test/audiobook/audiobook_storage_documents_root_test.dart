import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:fushi_audio/src/audiobook/audiobook_storage.dart';
import 'package:path/path.dart' as p;

/// TODO-1236: `AudiobookStorage` 的 documents 根解析必须可被 app 层注入，使有声书
/// 持久写入随桌面「自定义数据根」走；未注入时退回平台 Documents（默认根）。
///
/// 直接断言 [AudiobookStorage.audiobooksRootDir]（派生自私有 `_documentsRoot`）：
///  - 注入自定义根 → `<custom>/audiobooks`（模拟自定义数据根生效）。
///  - 未注入（resolver=null）→ 退回 `getApplicationDocumentsDirectory()`（默认根）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    // 隔离：每个用例后清掉注入钩子与 path_provider mock。
    AudiobookStorage.documentsRootResolver = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
  });

  test('注入自定义数据根 → 有声书持久根落新根下的 audiobooks/', () async {
    final Directory custom =
        Directory(p.join(Directory.systemTemp.path, 'todo1236_custom_root'));
    AudiobookStorage.documentsRootResolver = () async => custom;

    final String root = await AudiobookStorage.audiobooksRootDir();

    expect(p.equals(root, p.join(custom.path, 'audiobooks')), isTrue,
        reason: '自定义数据根生效时新写入应落 <custom>/audiobooks，实际=$root');
  });

  test('未注入 resolver → 退回平台 Documents（默认根）', () async {
    final Directory platformDocs =
        await Directory.systemTemp.createTemp('todo1236_default_docs_');
    addTearDown(() {
      if (platformDocs.existsSync()) platformDocs.deleteSync(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return platformDocs.path;
        }
        return null;
      },
    );

    // resolver 未注入（tearDown 已保证 null，这里显式再置一次表达契约）。
    AudiobookStorage.documentsRootResolver = null;

    final String root = await AudiobookStorage.audiobooksRootDir();

    expect(p.equals(root, p.join(platformDocs.path, 'audiobooks')), isTrue,
        reason: '未注入时应退回平台 Documents/audiobooks，实际=$root');
  });
}
