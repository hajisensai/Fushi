import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-2039 ③ 停驻 realm 的**登记面**守卫（目录枚举型：扫 `lib/` 全树）。
///
/// 为什么必须有这个文件：`buildParkedRealmLayers` / `parkedRealmPopupLayer` 在
/// `test/` 与 `integration_test/` 下**零命中**——这套机制此前一条测试都没有。
///
/// 而它的失效是静默的：`DictionaryPopupController._retireEntries` 是所有出栈路径
/// 的必经处，任何宿主一旦有层离栈，键就进 `parkedRealms`；宿主**不把这些键渲染
/// 在屏外**，键背后的 element 当帧就被销毁，下一次 `_takeRealmKey()` 接管到的是
/// 一把已死的键 ⇒ 嵌套查词退回冷建 WebView。**测试全绿、analyze 全绿，只有用户
/// 觉得慢**。实测本守卫写出来时，`popup_dictionary_page.dart` 正是这样一个建了
/// 控制器却一处都没接的宿主。
///
/// 判据取「谁**建**了 `DictionaryPopupController`」而不是硬编码文件清单：新增第
/// 八个宿主时它自动落进扫描面（点名清单型守卫对新文件是零覆盖的）。
void main() {
  final Directory libRoot = Directory('lib');

  late List<({String path, String code})> hosts;

  setUpAll(() {
    expect(libRoot.existsSync(), isTrue,
        reason: 'flutter test 的 cwd 应是 fushi 包根');
    hosts = <({String path, String code})>[];
    for (final FileSystemEntity e in libRoot.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String path = e.path.replaceAll(r'\', '/');
      // 控制器自己的文件里那处 `DictionaryPopupController(` 是构造器声明，不是宿主。
      if (path.endsWith('implementations/dictionary_popup_controller.dart')) {
        continue;
      }
      final String code = maskComments(e.readAsStringSync());
      if (!code.contains('DictionaryPopupController(')) continue;
      hosts.add((path: path, code: code));
    }
  });

  test('每个建了 DictionaryPopupController 的宿主都渲染停驻 realm 层', () {
    final List<String> missing = <String>[
      for (final ({String path, String code}) h in hosts)
        if (!h.code.contains('parkedRealmPopupLayers(') &&
            !h.code.contains('buildParkedRealmLayers('))
          h.path,
    ];
    expect(
      missing,
      isEmpty,
      reason: '这些宿主建了弹窗控制器却从不渲染 parkedRealms：'
          '${missing.join(", ")}。'
          '控制器照常停驻离栈层的 WebView 键，宿主不挂在屏外 = 键背后的 element '
          '当帧销毁，下次嵌套查词静默退回冷建。',
    );
  });

  test('扫描规模下界：宿主数不得低于 7（漏扫会让本守卫真空通过）', () {
    // 现有七个：base_source_page / home_dictionary_page / texthooker_page /
    // video_fushi_page / web_video_fushi_page / floating_lyric_lookup_host /
    // popup_dictionary_page。数字只是下界哨兵——新增宿主会让它往上走，
    // 往下掉一定是枚举器或判据坏了，不是「宿主变少了」。
    expect(hosts.length, greaterThanOrEqualTo(7),
        reason: '只扫到 ${hosts.length} 个宿主：枚举根或判据漂了');
  });

  test('循环体只许有一份：parkedRealmPopupLayer 单数形只在它自己的文件里被引用', () {
    // `base_source_page.dart` 曾把 helper 的循环体内联抄了一遍（对照
    // `dictionary_page_mixin.dart`）。两份实现意味着「改一处、另一处不动」，
    // 而两处的差异不会有任何测试看得见。
    final List<String> offenders = <String>[];
    for (final FileSystemEntity e in libRoot.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String path = e.path.replaceAll(r'\', '/');
      if (path.endsWith('implementations/dictionary_popup_layer.dart')) {
        continue;
      }
      final String code = maskComments(e.readAsStringSync());
      // 复数形是共享原语，单数形是它的内部实现细节。
      final String stripped = code.replaceAll('parkedRealmPopupLayers(', '');
      if (stripped.contains('parkedRealmPopupLayer(')) offenders.add(path);
    }
    expect(offenders, isEmpty,
        reason: '这些文件绕过共享原语直接铺单层：${offenders.join(", ")}');
  });
}
