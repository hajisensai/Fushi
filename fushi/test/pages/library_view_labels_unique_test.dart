import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/source_guard.dart';

/// BUG-1710 的根因守卫：**同一个 tab 栏里不得出现两个字面相同的标签**。
///
/// 事故形态：漫画库同时挂着 `library_view_discover`（「发现」）和
/// `library_view_browse`（原「浏览」）两个视图；后来有人把 `library_view_browse`
/// 的文案也改成「发现 / Discover」，两个 tab 于是字面完全相同，用户点哪个都叫
/// 「发现」。改 i18n 的人不可能记得哪些 key 被同一个 tab 栏同时消费——**只有守卫
/// 能记住**。这条测试因此同时守两侧：加视图的人不能撞已有文案，改文案的人也不能
/// 把两个 key 改成同一句。
///
/// 判据取 **en + zh-CN 两个 locale**：只看 key 不重复是不够的（本次事故里两个 key
/// 本来就不同），必须看**用户真正看到的那串字**。
///
/// 扫描面是 `lib/` 全树（`listSync(recursive: true)`），新库页壳自动落进来，不用
/// 维护清单。
List<File> _dartFiles(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((File file) => file.path.endsWith('.dart'))
    .toList(growable: false);

/// `MediaLibraryViewSpec(` 的**使用点**（构造器声明是 `MediaLibraryViewSpec({`，
/// 后面跟的是 `required this.kind`，不是 `kind:`）。
final RegExp _specUse = RegExp(r'MediaLibraryViewSpec\(\s*kind:');

/// 使用点总数（含构造器声明），用来反证上面的正则没漏掉某个 spec。
final RegExp _specAny = RegExp(r'MediaLibraryViewSpec\(');

final RegExp _label = RegExp(r'label:\s*([^,\n]+),');

/// 只接受 `t.<key>` 形式的标签：拼接出来的字符串没法在源码层面比对，
/// 也就等于给这条守卫开了个后门。
final RegExp _tKey = RegExp(r'^t\.([A-Za-z0-9_]+)$');

Map<String, String> _translations(String file) {
  final Map<String, Object?> json =
      jsonDecode(File(p.join('lib', 'i18n', file)).readAsStringSync())
          as Map<String, Object?>;
  return json.map(
    (String key, Object? value) => MapEntry<String, String>(key, '$value'),
  );
}

/// 扫全树，返回「源文件 -> 该文件声明的视图标签 i18n key（按声明顺序）」。
///
/// 内含 `expect`，必须在测试体里调用（每个用例各扫一遍，几百个文件毫秒级）。
Map<String, List<String>> _collectLabels() {
  final Map<String, List<String>> labelsByFile = <String, List<String>>{};
  for (final File file in _dartFiles('lib')) {
    // 掩注释：本仓真实抓到过「把断言字面量塞进注释骗绿」，反过来说明注释里的
    // `MediaLibraryViewSpec(` 也会把这条守卫打成假红。
    final String source = maskComments(file.readAsStringSync());
    if (!source.contains('MediaLibraryViewSpec(')) continue;
    // 构造器声明所在的文件（`media_library_shell.dart`）没有使用点，跳过。
    final int uses = _specUse.allMatches(source).length;
    if (uses == 0) continue;
    final int total = _specAny.allMatches(source).length;
    expect(
      uses,
      total,
      reason: '${file.path}：有 ${total - uses} 个 MediaLibraryViewSpec 没被本守卫的'
          '正则认出来（`kind:` 不再是第一个具名参数？），标签会漏检',
    );
    final List<String> keys = <String>[];
    for (final RegExpMatch use in _specUse.allMatches(source)) {
      // 一个 spec 的三个具名参数挨在一起，往后取一小段足够覆盖 label。
      final int end = (use.start + 600).clamp(0, source.length);
      final RegExpMatch? label =
          _label.firstMatch(source.substring(use.start, end));
      expect(
        label,
        isNotNull,
        reason: '${file.path}：MediaLibraryViewSpec 必须显式给 label',
      );
      final String expression = label!.group(1)!.trim();
      final RegExpMatch? key = _tKey.firstMatch(expression);
      expect(
        key,
        isNotNull,
        reason: '${file.path}：tab 标签必须是 `t.<key>` 直引用（拿到的是 '
            '`$expression`）。拼接出来的标签没法在源码层面比对重复，'
            '等于给这条守卫开后门',
      );
      keys.add(key!.group(1)!);
    }
    labelsByFile[file.path.replaceAll(r'\', '/')] = keys;
  }
  return labelsByFile;
}

void main() {
  group('库页 tab 标签在同一栏内不得重复', () {
    test('扫描面非空：库页壳文件确实被找到了', () {
      final Map<String, List<String>> labelsByFile = _collectLabels();
      // 零文件也能让下面的断言全绿——这条就是防「守卫其实什么都没看」。
      expect(labelsByFile.length, greaterThanOrEqualTo(2),
          reason: '至少书 tab 与漫画库页两处声明视图；一个都没扫到说明正则失效了');
      expect(
        labelsByFile.keys,
        contains('lib/src/media/manga/manga_library_page.dart'),
        reason: 'BUG-1710 就出在漫画库页，它必须在扫描面里',
      );
      for (final MapEntry<String, List<String>> entry in labelsByFile.entries) {
        expect(entry.value.length, greaterThanOrEqualTo(2),
            reason: '${entry.key}：一个 tab 栏至少两个视图，否则壳不会渲染导航条');
      }
    });

    test('同一栏内的 i18n key 不重复', () {
      for (final MapEntry<String, List<String>> entry
          in _collectLabels().entries) {
        expect(
          entry.value.toSet().length,
          entry.value.length,
          reason: '${entry.key}：同一个 tab 栏里有两个视图用了同一个 i18n key '
              '(${entry.value})',
        );
      }
    });

    for (final String locale in <String>['strings', 'strings_zh-CN']) {
      test('同一栏内的 $locale 文案不重复（BUG-1710 的直接判据）', () {
        final Map<String, String> table = _translations('$locale.i18n.json');
        for (final MapEntry<String, List<String>> entry
            in _collectLabels().entries) {
          final Map<String, String> seen = <String, String>{};
          for (final String key in entry.value) {
            final String? text = table[key];
            expect(text, isNotNull,
                reason: '${entry.key}：i18n key `$key` 在 $locale 里不存在');
            final String? owner = seen[text];
            expect(
              owner,
              isNull,
              reason: '${entry.key}：$locale 下 `$owner` 与 `$key` 的文案都是 '
                  '「$text」——同一个 tab 栏里出现两个字面相同的标签，'
                  '用户点哪个都分不清（BUG-1710）',
            );
            seen[text!] = key;
          }
        }
      });
    }
  });
}
