import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-609：词典管理「更新词典」UI 源码守卫。
///
/// 这套行为天然需要真 AppModel + InAppWebView（词典查询/资源目录），headless
/// widget 测试起不来；纯函数（isUpdatable / needsUpdate / readSourceMetadataFromIndex /
/// decideUpdate）已各有单测覆盖。本守卫锁住 UI 接线的关键不变量，防回归：
/// - 行更新按钮**仅** isUpdatable 时显示（向后兼容：旧词典不显示、不崩）。
/// - action bar「更新全部词典」常驻首位（不再按 isUpdatable 存在性门控：旧版导入的
///   词典缺来源字段时入口整个消失，用户只找得到要自己下新包的行尾按钮）。
/// - 更新下载远端 index 声明的新包地址，远端检查失败不算「已是最新」。
/// - 单本/批量/从文件更新都以被点击词典为显式替换目标（replaceTarget，BUG-1595）。
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

  test('TODO-839：从文件覆盖更新走显式替换 + 异名确认接线', () {
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

  test('action bar「更新全部词典」常驻且排第一，桌面/移动动作栏同样有', () {
    expect(
      src.contains(
          'appModel.dictionaries.any((Dictionary d) => d.isUpdatable)'),
      isFalse,
      reason: '更新全部词典按钮不得再按可更新词典存在性隐藏',
    );
    final int bar = src.indexOf('Widget _buildActionBar()');
    final int update = src.indexOf("focusPrefix: 'dict-action-update'", bar);
    final int download =
        src.indexOf("focusPrefix: 'dict-action-download'", bar);
    expect(update, greaterThan(bar));
    expect(update, lessThan(download), reason: '更新全部词典应排在第一个');
    expect('label: t.dict_update_all,'.allMatches(src).length, 2,
        reason: 'Material 动作栏 + 移动端溢出菜单');
    expect('tooltip: t.dict_update_all,'.allMatches(src).length, 1,
        reason: '桌面 Cupertino 动作栏');
    expect(src.contains('msg: t.dict_update_all_no_source,'), isTrue,
        reason: '没有可在线更新词典时要说明原因，而不是说「均为最新」');
  });

  test('更新下载远端 index 声明的新包地址；检查失败不算最新', () {
    // BUG-2707（#1670）：单本与批量共用 _redownloadAndReimport 漏斗，漏斗里唯一一处
    // `remote.resolveDownloadUrl(` 选址；两个调用点都得把远端结果传进去。
    expect(
      'remote.resolveDownloadUrl('.allMatches(src).length,
      1,
      reason: '下载选址只在 _redownloadAndReimport 漏斗里做一次',
    );
    expect(
      'remote: remote,'.allMatches(src).length,
      2,
      reason: '单本与批量更新都必须把远端 index 结果传进漏斗（钉版本号的包地址）',
    );
    expect(
      src,
      matches(RegExp(
          r'if \(!remote\.succeeded\) \{\s*return DictionaryDownloadOutcome\(\s*message: t\.dict_update_check_failed,')),
      reason: '单本更新拉不到远端 index 要报「检查失败」，不能落到「已是最新」',
    );
    expect(src.contains('url: dictionary.downloadUrl,'), isFalse,
        reason: '不得再用本地存的旧版本地址下载');
    expect(src.contains('t.dict_update_check_failed'), isTrue);
    expect(
      src,
      matches(RegExp(r'if \(!remote\.succeeded\) \{\s*failed\+\+;')),
      reason: '批量更新里拉不到远端 index 要计入失败',
    );
  });

  test('非可在线更新词典的行尾按钮 tooltip 说明是从本地文件更新', () {
    expect(src.contains('t.dict_update_from_file_tooltip'), isTrue);
  });

  test('单本/批量/从文件更新以被点击词典为显式替换目标（replaceTarget）', () {
    // BUG-1595（PR #816）：force 重导按新包 title 判重，标题携带版本号的新版会被
    // 误判 newDictionary 追加成两版并存。更新链路改为显式 replaceTarget（decideUpdate
    // 的 hasReplaceTarget 恒 replaceExact），替换语义不再依赖 title 匹配。
    // 两处调用点：_redownloadAndReimport（在线单本/批量更新共用漏斗）与
    // _updateDictionaryFromFile（本地从文件覆盖更新）。
    expect('replaceTarget: dictionary,'.allMatches(src).length, 2,
        reason: '在线更新漏斗与从文件覆盖更新都必须以被点击词典为显式替换目标');
    expect(src.contains('forceReplaceExisting'), isFalse,
        reason: '更新链路不得回退到按 title 判重的 force 重导（BUG-1595 旧陷阱）');
  });

  test('比对走 DictionaryUpdateService（fetchRemoteIndexResult + needsUpdate）', () {
    expect(
        src.contains('DictionaryUpdateService.fetchRemoteIndexResult'), isTrue);
    expect(src.contains('DictionaryUpdateService.needsUpdate'), isTrue);
  });

  // BUG-2707：手动（单本 / 全部）与启动自动更新三条链路都必须按远端 index 声明的
  // 新版地址下载、并把它回写进 metadata。本地记录的 downloadUrl 可能钉在旧版本
  // 目录（Pixiv Light）或旧包名（COBUILD8），拿它下载等于把旧包重导一遍。
  test('BUG-2707：更新链路按远端 index 的新版地址下载与回写', () {
    final String appModelSrc =
        File('lib/src/models/app_model.dart').readAsStringSync();
    for (final MapEntry<String, String> e in <String, String>{
      'dictionary_dialog_page.dart': src,
      'app_model.dart': appModelSrc,
    }.entries) {
      expect(e.value.contains('remote.resolveDownloadUrl('), isTrue,
          reason: '${e.key}：下载地址必须取远端 index 声明的新版');
      expect(e.value.contains('remote.updatedSourceMetadata('), isTrue,
          reason: '${e.key}：回写来源必须推进到远端地址');
      expect(
          RegExp(r"'downloadUrl':\s*(dictionary|d)\.downloadUrl")
              .hasMatch(e.value),
          isFalse,
          reason: '${e.key}：不得把本地旧 downloadUrl 原样回写');
      expect(
          RegExp(r'url:\s*dictionary\.downloadUrl').hasMatch(e.value), isFalse,
          reason: '${e.key}：不得直接拿本地旧 downloadUrl 下载');
    }
  });

  test('在线下载落来源（catalog 回填 downloadUrl，可更新源再补 isUpdatable+indexUrl）', () {
    // TODO-1075：初装即把可更新性锚定在 catalog 来源真值。
    // - 恒回填 downloadUrl（供更新时重下载）。
    expect(src.contains("'downloadUrl': rec.url"), isTrue,
        reason: '下载在线词典必须把 catalog url 当 downloadUrl 回填来源');
    // - 对存在分离 index 端点的来源，据 rec.indexUrl 回填 isUpdatable:'true' + indexUrl，
    //   让 catalog 导入的词典初装即 isUpdatable==true（修初装 gate 空档）。
    expect(src.contains('final String? recIndexUrl = rec.indexUrl;'), isTrue,
        reason: 'catalog 导入应读 rec.indexUrl 判定该来源是否可在线更新');
    expect(src.contains("'isUpdatable': 'true',"), isTrue,
        reason: '可更新源导入必须回填 isUpdatable:true');
    expect(src.contains("'indexUrl': recIndexUrl,"), isTrue,
        reason: '可更新源导入必须回填分离 index 端点 URL');
  });
}
