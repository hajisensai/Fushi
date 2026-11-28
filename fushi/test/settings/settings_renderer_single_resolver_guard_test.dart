import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

// 设置渲染器只有 MD3 / 玻璃两个实现，选哪个只由 `resolveSettingsRenderer`
// （lib/src/settings/settings_renderer.dart）决定，它同时是 lib 里唯一 new 渲染器
// 的地方。隐藏的 Cupertino 渲染器删掉之前，设置主页 / 详情页 / 模块页签各自判
// 设计系统、各自 new 渲染器，三处判据并不一致；这里把「再出现第二个选择点或
// 第三个实现」卡成写不出来。
//
// 测试代码直接 new 某个渲染器来钉住它的行为不受限，本守卫只扫 lib。

const String _resolverFile = 'lib/src/settings/settings_renderer.dart';
const String _materialFile = 'lib/src/settings/material_settings_renderer.dart';
const String _glassFile = 'lib/src/settings/glass_settings_renderer.dart';

/// 渲染器类名后面直接跟 `(`：构造调用，或类自己的构造器声明。
final RegExp _rendererConstruction = RegExp(
  r'\b(?:Material|Glass)SettingsRenderer\s*\(',
);

/// 新的 [SettingsRenderer] 实现（implements / extends / with）。
final RegExp _rendererImplementation = RegExp(
  r'\b(?:implements|extends|with)\b[^{;()=]*\bSettingsRenderer\b',
);

/// 允许出现的渲染器构造数：选择函数里两处（MD3 / 玻璃各一），两个类各自的
/// 构造器声明一处。
const Map<String, int> _allowedConstructions = <String, int>{
  _resolverFile: 2,
  _materialFile: 1,
  _glassFile: 1,
};

const Map<String, int> _allowedImplementations = <String, int>{
  _materialFile: 1,
  _glassFile: 1,
};

/// 单个文件的违规清单：数量必须与允许值**相等**（多了是新选择点 / 新实现，
/// 少了说明允许表过期）。
List<String> rendererGuardOffenders(String path, String source) {
  final String code = maskCommentsAndStrings(source);
  final List<String> offenders = <String>[];
  final int constructions = _rendererConstruction.allMatches(code).length;
  final int allowedConstructions = _allowedConstructions[path] ?? 0;
  if (constructions != allowedConstructions) {
    offenders.add(
      '$path: $constructions settings renderer construction(s), expected '
      '$allowedConstructions — 渲染器只许由 resolveSettingsRenderer 构造',
    );
  }
  final int implementations = _rendererImplementation.allMatches(code).length;
  final int allowedImplementations = _allowedImplementations[path] ?? 0;
  if (implementations != allowedImplementations) {
    offenders.add(
      '$path: $implementations SettingsRenderer implementation(s), expected '
      '$allowedImplementations — 设置渲染器只有 MD3 / 玻璃两个实现',
    );
  }
  return offenders;
}

void main() {
  test('lib 里只有 resolveSettingsRenderer 构造设置渲染器，实现只有两个', () {
    final List<String> offenders = <String>[];
    final Set<String> seen = <String>{};
    for (final FileSystemEntity entity in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('.g.dart')) continue;
      final String path = entity.path.replaceAll(r'\', '/');
      final String source = entity.readAsStringSync();
      // 快路径：不提渲染器名字的文件不可能违规，免掉整文件词法扫描。
      if (!source.contains('SettingsRenderer')) continue;
      seen.add(path);
      offenders.addAll(rendererGuardOffenders(path, source));
    }
    for (final String path in <String>{
      ..._allowedConstructions.keys,
      ..._allowedImplementations.keys,
    }) {
      expect(seen, contains(path), reason: '允许表里的 $path 没扫到，表过期了');
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('选择函数只按玻璃判据二选一', () {
    final String code = compactCode(File(_resolverFile).readAsStringSync());
    expect(
      code,
      contains(
        'returnisGlassDesign(context)'
        '?GlassSettingsRenderer(showDetailHeader:showDetailHeader)'
        ':MaterialSettingsRenderer(showDetailHeader:showDetailHeader);',
      ),
    );
  });

  group('守卫自检', () {
    test('页面里自己 new 渲染器会被报出来', () {
      const String source = '''
Widget build(BuildContext context) {
  const MaterialSettingsRenderer renderer = MaterialSettingsRenderer();
  return renderer.buildDetailPage(settingsContext: c, destination: d);
}
''';
      expect(
        rendererGuardOffenders('lib/src/pages/some_page.dart', source),
        isNotEmpty,
      );
    });

    test('const 构造与带参构造同样算', () {
      const String source =
          'final SettingsRenderer r = glass '
          '? const GlassSettingsRenderer(showDetailHeader: true) '
          ': const MaterialSettingsRenderer();';
      expect(
        rendererGuardOffenders('lib/src/pages/some_page.dart', source),
        isNotEmpty,
      );
    });

    test('第三个渲染器实现会被报出来', () {
      const String source =
          'class CupertinoSettingsRenderer implements SettingsRenderer {}';
      expect(
        rendererGuardOffenders('lib/src/settings/third.dart', source),
        isNotEmpty,
      );
    });

    test('只引用静态成员 / 类型、或只在注释和字符串里提到，不算', () {
      const String source = '''
// const MaterialSettingsRenderer() 这样的注释不算。
/* GlassSettingsRenderer( */
const String note = 'MaterialSettingsRenderer(';
final double w = MaterialSettingsRenderer.navPaneWidth;
final SettingsRenderer r = resolveSettingsRenderer(context);
final bool glass = r is GlassSettingsRenderer;
''';
      expect(
        rendererGuardOffenders('lib/src/pages/some_page.dart', source),
        isEmpty,
      );
    });

    test('选择函数文件里多出第三处构造也红', () {
      const String source = '''
SettingsRenderer a() => GlassSettingsRenderer();
SettingsRenderer b() => MaterialSettingsRenderer();
SettingsRenderer c() => MaterialSettingsRenderer(showDetailHeader: true);
''';
      expect(rendererGuardOffenders(_resolverFile, source), isNotEmpty);
    });
  });
}
