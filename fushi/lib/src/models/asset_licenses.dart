import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 开源许可页里由 app 自己注册的许可（pub 包之外的部分）。
///
/// 两类来源，都**不手写名字清单**：
/// * `assets/licenses/*.txt`：手工放进来的单份许可（内置脚本 / 字体 / 数据表等），
///   按资产清单枚举，包名取文件名；
/// * `assets/licenses/native/`：`tool/native_licenses.dart` 生成的原生依赖许可汇编
///   （Rust crate + C/C++ 库，按许可文本去重），按其 `index.json` 注册。
///
/// 守卫 `test/build/native_license_registry_guard_test.dart` 钉死两者都被完整注册。
const String kAssetLicenseDir = 'assets/licenses/';

/// 原生依赖许可汇编的索引资产。
const String kNativeLicenseIndexAsset = 'assets/licenses/native/index.json';

/// 顶层手工许可文件的包名：文件名去掉 `.txt` 与可有可无的 `_LICENSE` 后缀。
String assetLicensePackageName(String assetKey) {
  String name = assetKey.substring(kAssetLicenseDir.length);
  name = name.substring(0, name.length - '.txt'.length);
  const String suffix = '_LICENSE';
  if (name.endsWith(suffix)) {
    name = name.substring(0, name.length - suffix.length);
  }
  return name;
}

/// 是否是顶层手工许可文件（`assets/licenses/<名>.txt`，不含子目录）。
bool isTopLevelAssetLicense(String assetKey) =>
    assetKey.startsWith(kAssetLicenseDir) &&
    assetKey.endsWith('.txt') &&
    !assetKey.substring(kAssetLicenseDir.length).contains('/');

/// 读出全部资产许可条目。[assetKeys] 是资产清单里的全部 key，[loadString] 读资产文本。
Future<List<LicenseEntry>> loadAssetLicenseEntries({
  required Iterable<String> assetKeys,
  required Future<String> Function(String key) loadString,
}) async {
  final List<String> keys = assetKeys.toList()..sort();
  final List<LicenseEntry> entries = <LicenseEntry>[];
  for (final String key in keys.where(isTopLevelAssetLicense)) {
    entries.add(
      LicenseEntryWithLineBreaks(<String>[
        assetLicensePackageName(key),
      ], await loadString(key)),
    );
  }
  if (keys.contains(kNativeLicenseIndexAsset)) {
    final Map<String, dynamic> index =
        jsonDecode(await loadString(kNativeLicenseIndexAsset))
            as Map<String, dynamic>;
    for (final dynamic raw in index['licenses'] as List<dynamic>) {
      final Map<String, dynamic> license = raw as Map<String, dynamic>;
      entries.add(
        LicenseEntryWithLineBreaks(
          (license['packages'] as List<dynamic>).cast<String>(),
          await loadString(
            '${kAssetLicenseDir}native/${license['file'] as String}',
          ),
        ),
      );
    }
  }
  return entries;
}

/// 把资产许可挂到 [LicenseRegistry]。读资产推迟到许可页真正收集许可时，不占启动时间。
void registerAssetLicenses(AssetBundle bundle) {
  LicenseRegistry.addLicense(() async* {
    final AssetManifest manifest = await AssetManifest.loadFromAssetBundle(
      bundle,
    );
    yield* Stream<LicenseEntry>.fromIterable(
      await loadAssetLicenseEntries(
        assetKeys: manifest.listAssets(),
        loadString: bundle.loadString,
      ),
    );
  });
}
