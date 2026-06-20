import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-609：词典管理「更新词典」UI 源码守卫。
///
/// 这套行为天然需要真 AppModel + InAppWebView（词典查询/资源目录），headless
/// widget 测试起不来；纯函数（isUpdatable / needsUpdate / readSourceMetadataFromIndex /
/// decideUpdate）已各有单测覆盖。本守卫锁住 UI 接线的关键不变量，防回归：
/// - 行更新按钮**仅** isUpdatable 时显示（向后兼容：旧词典不显示、不崩）。
/// - action bar「检查更新」按钮按 isUpdatable 存在性门控。
/// - 单本/批量更新都走 force 重导（forceReplaceExisting: true）。
/// - 在线下载落来源（sourceOverride 带 downloadUrl 回填）。
void main() {
  final File page = File(
    'lib/src/pages/implementations/dictionary_dialog_page.dart',
  );
  late String src;

  setUpAll(() {
    expect(page.existsSync(), isTrue,
        reason: 'dictionary_dialog_page.dart 应存在');
    src = page.readAsStringSync();
  });

  test('行更新按钮仅 isUpdatable 时显示', () {
    expect(src.contains('if (dictionary.isUpdatable)'), isTrue,
        reason: '词典行更新按钮必须 gate 在 dictionary.isUpdatable');
    expect(src.contains('_updateSingleDictionary(dictionary)'), isTrue,
        reason: '行更新按钮点击应调 _updateSingleDictionary');
  });

  test('action bar「检查更新」按 isUpdatable 存在性门控', () {
    expect(
      src.contains(
          'appModel.dictionaries.any((Dictionary d) => d.isUpdatable)'),
      isTrue,
      reason: '检查更新按钮应仅在存在可更新词典时显示',
    );
    expect(src.contains('onTap: _checkForUpdates'), isTrue);
  });

  test('单本/批量更新走 force 重导（forceReplaceExisting: true）', () {
    expect(src.contains('forceReplaceExisting: true'), isTrue,
        reason: '在线更新必须强制重导以替换同名旧版');
  });

  test('比对走 DictionaryUpdateService（fetchRemoteIndex + needsUpdate）', () {
    expect(src.contains('DictionaryUpdateService.fetchRemoteIndex'), isTrue);
    expect(src.contains('DictionaryUpdateService.needsUpdate'), isTrue);
  });

  test('在线下载落来源（sourceOverride 回填 downloadUrl）', () {
    expect(
      src.contains("sourceOverride: <String, String>{'downloadUrl': rec.url}"),
      isTrue,
      reason: '下载在线词典必须把 catalog url 当 downloadUrl 回填来源',
    );
  });
}
