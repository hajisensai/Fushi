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

  test('TODO-839：行尾更新按钮对所有词典恢显示，按 isUpdatable 分流', () {
    // 不再 gate 在 `if (dictionary.isUpdatable)`，而是恒渲染一个按钮、点击时按 isUpdatable 三元分流：
    // 在线走 _updateSingleDictionary、本地走 _updateDictionaryFromFile。
    expect(src.contains('dictionary.isUpdatable'), isTrue,
        reason: '行尾更新按钮 onTap 应按 dictionary.isUpdatable 三元分流');
    expect(src.contains('? _updateSingleDictionary(dictionary)'), isTrue,
        reason: 'isUpdatable 词典应走在线更新 _updateSingleDictionary');
    expect(src.contains(': _updateDictionaryFromFile(dictionary)'), isTrue,
        reason: '非 isUpdatable 词典应走从文件覆盖 _updateDictionaryFromFile');
  });

  test('TODO-839：从文件覆盖更新走 force 重导 + 异名确认接线', () {
    expect(src.contains('DictionaryImportManager.peekDictionaryTitle(file)'),
        isTrue,
        reason: '从文件更新前应帩价探出新包 title 判断异名');
    expect(src.contains('_confirmNameMismatch('), isTrue,
        reason: '异名时应弹亮确认对话框');
    expect(src.contains('t.dict_update_name_mismatch_body('), isTrue,
        reason: '异名确认对话框应引用 dict_update_name_mismatch_body 文案');
    expect(src.contains('DictionaryConfirmationDialog('), isTrue,
        reason: '异名确认应复用 DictionaryConfirmationDialog');
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
