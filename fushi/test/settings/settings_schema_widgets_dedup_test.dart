import 'dart:io';

import 'package:test/test.dart';

/// 源码守卫：schema section/item/footer 的渲染 widget 只有一份
/// （[settings_schema_widgets.dart]），material / cupertino 两个渲染器都复用它，
/// 平台差异（PageRoute 工厂、footer 文字样式）经 routeBuilder/footerStyle 参数注入，
/// 不再各自逐字节复制 ~210 行私有类。
void main() {
  String read(String p) => File(p).readAsStringSync();
  final String material = read(
    'lib/src/settings/material_settings_renderer.dart',
  );
  final String cupertino = read(
    'lib/src/settings/cupertino_settings_renderer.dart',
  );
  final String shared = read('lib/src/settings/settings_schema_widgets.dart');
  // footer 件挪到不碰 SettingsContext / AppModel 的叶子文件（防 lib/ 大 import
  // 环，见 import_cycle_guard_test.dart），由 settings_schema_widgets 转出。
  final String footer = read('lib/src/settings/settings_section_footer.dart');

  group('schema 渲染 widget 收口共享 (settings_schema_widgets)', () {
    test('共享文件定义 Section/Item/Footer + 参数化 routeBuilder/footerStyle', () {
      expect(shared, contains('class SettingsSchemaSection'));
      expect(shared, contains('class SettingsSchemaItem'));
      expect(footer, contains('class SettingsSectionFooter'));
      expect(
        shared,
        contains(
          "export 'package:fushi/src/settings/settings_section_footer.dart';",
        ),
        reason: '共享 widget 文件应转出 footer 件，渲染器只 import 一处',
      );
      expect(
        shared.contains('class SettingsSectionFooter'),
        isFalse,
        reason: 'footer 只能有一份定义（叶子文件）',
      );
      expect(
        footer.contains('settings_context.dart') ||
            footer.contains('app_model.dart'),
        isFalse,
        reason: '叶子文件不得依赖 SettingsContext / AppModel',
      );
      expect(shared, contains('footerStyle'), reason: 'footer 文字样式应作参数（两平台不同）');
      expect(
        shared,
        contains('routeBuilder'),
        reason: 'PageRoute 工厂应作参数（两平台不同）',
      );
      expect(
        shared,
        contains('dispatchChange('),
        reason: 'segmented 派发应走类型安全 dispatchChange',
      );
    });

    test('两渲染器不再各自定义私有 schema widget（已收口）', () {
      for (final String src in <String>[material, cupertino]) {
        expect(src.contains('class _SettingsSchemaItem'), isFalse);
        expect(src.contains('class _SettingsSchemaSection'), isFalse);
        expect(src.contains('class _SettingsSectionFooter'), isFalse);
      }
    });

    test('两渲染器复用共享 widget 并各自注入平台 PageRoute/footerStyle', () {
      for (final String src in <String>[material, cupertino]) {
        expect(src, contains('SettingsSchemaSection('));
        expect(src, contains('SettingsSchemaItem('));
        expect(src, contains('footerStyle:'));
        expect(
          src,
          contains(
            "import 'package:fushi/src/settings/settings_schema_widgets.dart';",
          ),
        );
      }
      expect(material, contains('MaterialPageRoute<void>(builder: builder)'));
      expect(cupertino, contains('CupertinoPageRoute<void>(builder: builder)'));
    });
  });
}
