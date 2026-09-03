import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/source_guard.dart';

/// `opds_atom_parser.dart` 的命名空间纪律守卫。
///
/// 这个文件是被 `opds_atom_parser.dart` 的库文档注释**点名**的守卫（「守卫见
/// `test/media/discovery/sources/opds_atom_namespace_test.dart`」），此前只有那句
/// 承诺、文件并不存在。
///
/// 要守的不变式：`package:xml` 的 `findAllElements` / `findElements` /
/// `getAttribute` 不传 `namespace` 时按 **qualified name** 匹配——`'entry'` 匹配
/// 不到 `<atom:entry>`。OPDS feed 允许任意前缀绑定 Atom / OPDS / Dublin Core
/// 命名空间，实测各服务端写法完全不一致（Calibre-Web 发裸 `<entry>`，某些代理层
/// 发 `<atom:entry>`）。漏一处的症状是整个目录解析成 0 条，表现为「这台 OPDS
/// 服务器连不上/是空的」——**没有任何报错**。
///
/// 修法不是逐个调用点补 `namespace: '*'`（下次新增查找还会漏），而是让按
/// local-name 匹配成为本文件里**唯一**的查找方式。这条守卫钉的就是「唯一」。
void main() {
  final File source = File(
    'lib/src/media/discovery/sources/opds/opds_atom_parser.dart',
  );

  late String code;

  setUpAll(() {
    expect(source.existsSync(), isTrue, reason: '解析器文件路径变了就改这里');
    // 必须剥注释：库文档注释里就写着 `findAllElements`、`getAttribute('count')`
    // 这些字面量，不剥的话下面的计数一律被注释里那几份带偏。
    code = maskComments(source.readAsStringSync());
  });

  test('每个 findAllElements / findElements 调用都带 namespace: \'*\'', () {
    final RegExp call = RegExp(r'\.find(All)?Elements\([^)]*\)');
    final List<String> sites =
        call.allMatches(code).map((RegExpMatch m) => m.group(0)!).toList();
    expect(sites, isNotEmpty, reason: '一个查找都没有 = 锚点漂了，不是真的干净');
    for (final String site in sites) {
      expect(
        site.contains("namespace: '*'"),
        isTrue,
        reason: '$site 少了 namespace: \'*\'，带前缀的元素会整批匹配不到',
      );
    }
  });

  test('getAttribute 只出现在 _attribute 原语里', () {
    final int total = 'getAttribute('.allMatches(code).length;
    final int start = code.indexOf('String? _attribute(XmlElement element');
    expect(start, greaterThan(-1), reason: '_attribute 原语没了或改名了');
    final String primitive = code.substring(start);
    final int inside = 'getAttribute('.allMatches(primitive).length;
    expect(
      inside,
      total,
      reason: '_attribute 之外还有 ${total - inside} 处裸 getAttribute：'
          '`thr:count` / `opds:facetGroup` 这类带前缀的属性会取不到',
    );
    expect(
      primitive.contains("element.getAttribute(localName, namespace: '*')"),
      isTrue,
      reason: '_attribute 必须保留带 namespace 的回落，否则它自己就是个裸查找',
    );
  });

  test('三个查找原语都在（守卫的锚点本身不许被悄悄删掉）', () {
    for (final String primitive in <String>[
      'Iterable<XmlElement> _elements(XmlNode node, String localName)',
      'Iterable<XmlElement> _childElements(XmlElement parent, String localName)',
      'String? _attribute(XmlElement element, String localName)',
    ]) {
      expect(code, contains(primitive), reason: '原语 $primitive 不见了');
    }
  });
}
