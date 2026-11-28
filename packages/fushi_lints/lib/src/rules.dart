import 'ratchet.dart';
import 'rules/no_legacy_design_import.dart';
import 'rules/no_raw_design_controls.dart';
import 'rules/platform_dirs_via_app_paths.dart';
import 'rules/pure_dart_package_imports.dart';

/// 插件注册的全部规则。新增一条代码不变式 = 在这里加一个规则类 + 它的单测。
List<RatchetedRule> fushiRules() => <RatchetedRule>[
  NoLegacyDesignImport(),
  NoRawDesignControls(),
  PlatformDirsViaAppPaths(),
  PureDartPackageImports(),
];
