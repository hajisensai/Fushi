import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:path/path.dart' as p;

/// **发 2.0 正式版的硬门**：formal release 的资产表必须让**已出货的 Hibiki v1.2.0**
/// 命中迁移桥包，同时**一个字节都不改变在野 Fushi 客户端的选择**。
///
/// 守的不是本仓代码的行为，而是**改不了的两批外部二进制的行为**：
///
/// * **Hibiki v1.2.0**（老产品）：挑包判据是「`.apk` 结尾 + 名字含设备 `SUPPORTED_ABIS`
///   任一项」，且**完全不认产品族**（`assetBelongsToThisProduct` 是 BUG-1481 之后才有的）。
///   它会把本体 Fushi 的 APK 当成自己的更新装上——跨包名装成并存的第二个空 app，用户以为
///   换代完成卸掉 Hibiki，`/data/user/0/app.hibiki.reader/` 里的全部数据永久丢失。
/// * **已出货的 Fushi**（debug / beta 通道，线上 `latest-debug-fushi.json` 即其证据）：
///   `_channelsAdmittedBy` 让 `debug→[stable,beta,debug]`，所以**它们也会拉 stable 轨**，
///   用编译进包里的旧判据（产品族过滤 + ABI 全名子串 + `fallback ??= asset`）挑 2.0 的资产。
///   本体资产名一旦不含 ABI 串，它们就会退化到 fallback 拿到错架构包
///   （arm64 设备装 32 位 → versionCode 反而更小 → `INSTALL_FAILED_VERSION_DOWNGRADE`；
///   64 位 only 设备 → `INSTALL_FAILED_NO_MATCHING_ABIS`）。
///
/// 两条约束把方案钉死在唯一解上：**本体资产名保持 ABI 全名不动，改让桥包用一个字母序
/// 排在 `fushi-` 之前的前缀**（`bridge-`）。GitHub API 按文件名升序返回资产，于是
/// v1.2.0 先遇到桥包并 ABI 命中；Fushi 客户端的产品族白名单只认 `fushi-`，桥包对它们
/// 完全不可见，选择与没有桥包时逐字相同。
void main() {
  // ---------------------------------------------------------------------------
  // 两份**冻结的外部契约快照**：从 tag `v1.2.0` 与当前在野 Fushi 包的
  // `platform_updater.dart` 里逐字抄来的挑包逻辑。
  //
  // **永远不要**把它们「重构」成调用当前的 `AndroidUpdater`——那样用例就退化成自证，
  // 而它们要证的恰恰是「我们发布的资产表喂给再也改不动的旧二进制会发生什么」。
  // ---------------------------------------------------------------------------
  bool legacyIsDebugApkAsset(String name) =>
      name.endsWith('-debug.apk') || name.contains('-debug.');

  bool legacyMatchesStableChannel(String name) =>
      name.endsWith('.apk') && !legacyIsDebugApkAsset(name);

  /// GitHub API 按文件名升序返回资产（实测：`created_at` / `id` 均无序）。
  List<String> asGitHubReturnsThem(List<String> names) =>
      List<String>.from(names)..sort();

  /// Hibiki v1.2.0：无产品族过滤。
  String? hibikiV120Pick(List<String> assetNames, List<String> deviceAbis) {
    final List<String> abiTags =
        deviceAbis.map((String a) => a.replaceAll('_', '-')).toList();
    String? fallback;
    for (final String name in asGitHubReturnsThem(assetNames)) {
      if (!legacyMatchesStableChannel(name)) continue;
      if (abiTags.any(name.contains)) return name;
      fallback ??= name;
    }
    return fallback;
  }

  /// 在野 Fushi（BUG-1481 之后、本次改动之前）：多了产品族白名单，其余同上。
  String? shippedFushiPick(List<String> assetNames, List<String> deviceAbis) {
    final List<String> abiTags =
        deviceAbis.map((String a) => a.replaceAll('_', '-')).toList();
    String? fallback;
    for (final String name in asGitHubReturnsThem(assetNames)) {
      if (!name.startsWith('fushi-')) continue;
      if (!legacyMatchesStableChannel(name)) continue;
      if (abiTags.any(name.contains)) return name;
      fallback ??= name;
    }
    return fallback;
  }

  const String version = '2.0.0';

  /// 迁移桥包（旧包名 `app.hibiki.reader` + 旧签名 + 迁移导出器）挂在 2.0 正式版
  /// release 上时使用的前缀。**必须字母序小于 `fushi-`**，否则 v1.2.0 会先命中本体。
  const String bridgePrefix = 'bridge-';

  List<String> bridgeAssets(String prefix) => <String>[
        for (final String abi in kAndroidReleaseAbis)
          '$prefix$version-$abi.apk',
      ];

  /// 本体资产：与 [synthesizeStableAssetNames] 同源，保证守卫跟着真相源走。
  List<String> fushiAssets() => synthesizeStableAssetNames(version);

  List<String> formalReleaseAssets({String prefix = bridgePrefix}) =>
      <String>[...fushiAssets(), ...bridgeAssets(prefix)];

  /// 设备 `SUPPORTED_ABIS` 的真实取值（含 64 位设备同时上报的 32 位项）。
  const Map<String, List<String>> deviceAbis = <String, List<String>>{
    'arm64 设备': <String>['arm64-v8a', 'armeabi-v7a', 'armeabi'],
    'arm32 设备': <String>['armeabi-v7a', 'armeabi'],
    'x86_64 设备': <String>['x86_64', 'x86', 'armeabi-v7a', 'armeabi'],
  };

  group('桥包前缀必须字母序排在 fushi- 之前', () {
    test('bridge- < fushi-，这是整个方案成立的算术前提', () {
      expect(bridgePrefix.compareTo('fushi-') < 0, isTrue);
    });

    test('产品族白名单不认桥包前缀（Fushi 侧对它完全不可见）', () {
      for (final String name in bridgeAssets(bridgePrefix)) {
        expect(assetBelongsToThisProduct(name), isFalse);
      }
    });
  });

  group('CI 必须在发本体之前拦住「桥包缺席的正式版」', () {
    late String workflow;

    setUpAll(() {
      // 测试 cwd 是 `fushi/`，仓库根是上一级。
      final Directory repoRoot = Directory.current.parent;
      final File f =
          File(p.join(repoRoot.path, '.github', 'workflows', 'release.yml'));
      expect(f.existsSync(), isTrue,
          reason: 'repo root 解析错误: ${repoRoot.path}');
      workflow = f.readAsStringSync();
    });

    test('formal 通道有桥包存在性硬门，且排在上传本体资产之前', () {
      const String guard =
          '- name: Require migration bridge assets on the formal tag';
      const String publish = '- name: Publish Android channel release';
      expect(workflow.contains(guard), isTrue,
          reason: '删掉这道门 = 桥包晚到的窗口期里老 Hibiki 用户会丢数据');
      expect(workflow.indexOf(guard) < workflow.indexOf(publish), isTrue,
          reason: '必须在上传本体资产之前失败，事后报错拦不住已经上线的资产');
      expect(
        workflow
            .contains("if: steps.channel.outputs.manifest_channel == 'formal'"),
        isTrue,
      );
    });

    test('三个 ABI 逐个校验，且认的是 bridge- 前缀', () {
      for (final String abi in kAndroidReleaseAbis) {
        expect(
          workflow.contains('for abi in arm64-v8a armeabi-v7a x86_64;') &&
              workflow.contains(r'"^bridge-.*-${abi}\.apk$"'),
          isTrue,
          reason: '缺 $abi 的桥包校验',
        );
      }
    });
  });

  group('已出货 Hibiki v1.2.0 面对 2.0 正式版资产表', () {
    for (final MapEntry<String, List<String>> device in deviceAbis.entries) {
      test('${device.key}：命中桥包，绝不命中本体 Fushi 的 APK', () {
        final String? picked =
            hibikiV120Pick(formalReleaseAssets(), device.value);
        expect(picked, isNotNull);
        expect(
          picked!.startsWith(bridgePrefix),
          isTrue,
          reason: '跨包名装到 Fushi 上 = 并存空 app，用户卸旧包即永久丢数据；'
              '实际选中 $picked',
        );
      });
    }

    test('arm64 / arm32 各自命中本架构的桥包', () {
      expect(hibikiV120Pick(formalReleaseAssets(), deviceAbis['arm64 设备']!),
          '$bridgePrefix$version-arm64-v8a.apk');
      expect(hibikiV120Pick(formalReleaseAssets(), deviceAbis['arm32 设备']!),
          '$bridgePrefix$version-armeabi-v7a.apk');
    });

    test('x86_64 设备落到 armeabi 桥包：v1.2.0 自身的字母序缺陷，非本方案引入', () {
      // v1.2.0 拿资产列表做外层循环，命中任一设备 ABI 即返回，于是字母序更靠前的
      // armeabi-v7a 先命中（x86_64 设备的 SUPPORTED_ABIS 本来就带 armeabi-v7a）。
      // 判定可接受：x86_64 Android 只有模拟器 / Chromebook，上报 armeabi-v7a 就意味着
      // 有 ARM 翻译层，而桥包唯一职责是把数据导出来。关键是它**仍然是桥包**。
      expect(hibikiV120Pick(formalReleaseAssets(), deviceAbis['x86_64 设备']!),
          '$bridgePrefix$version-armeabi-v7a.apk');
    });

    test('反向：桥包若用 hibiki- 前缀（字母序在 fushi- 之后）就会失守', () {
      final String? picked = hibikiV120Pick(
          formalReleaseAssets(prefix: 'hibiki-'), deviceAbis['arm64 设备']!);
      expect(
        picked,
        'fushi-$version-arm64-v8a.apk',
        reason: '这就是前缀不能叫 hibiki- 的原因：老客户端会先命中本体',
      );
    });

    test('反向：桥包缺席时老客户端照样装到本体上——桥包资产不可省', () {
      final String? picked =
          hibikiV120Pick(fushiAssets(), deviceAbis['arm64 设备']!);
      expect(picked, 'fushi-$version-arm64-v8a.apk');
    });
  });

  group('挂桥包不得改变在野 Fushi 客户端的选择', () {
    // `_channelsAdmittedBy` 让 debug/beta 客户端也拉 stable 轨，它们用旧判据挑 2.0 资产。
    for (final MapEntry<String, List<String>> device in deviceAbis.entries) {
      test('${device.key}：有无桥包，选中的资产逐字相同', () {
        expect(
          shippedFushiPick(formalReleaseAssets(), device.value),
          shippedFushiPick(fushiAssets(), device.value),
        );
      });

      test('${device.key}：选中的必须是本体、且是按 ABI 命中而非 fallback', () {
        final String? picked =
            shippedFushiPick(formalReleaseAssets(), device.value);
        expect(picked, isNotNull);
        expect(picked!.startsWith('fushi-'), isTrue);
        final List<String> abiTags =
            device.value.map((String a) => a.replaceAll('_', '-')).toList();
        expect(abiTags.any(picked.contains), isTrue,
            reason: '退化到 fallback 就会拿到错架构包，装不上');
      });
    }
  });

  group('当前客户端：架构选择正确且不受资产顺序影响', () {
    Future<UpdateAsset?> pick(List<String> names, List<String> abis) =>
        AndroidUpdater(abiProvider: () async => abis)
            .selectAsset(<Map<String, dynamic>>[
          for (final String n in names)
            <String, dynamic>{
              'name': n,
              'browser_download_url': 'https://example.invalid/$n',
            },
        ]);

    test('三类设备各挑到本架构的 fushi 包，桥包在场也不选', () async {
      expect((await pick(formalReleaseAssets(), deviceAbis['arm64 设备']!))!.name,
          'fushi-$version-arm64-v8a.apk');
      expect((await pick(formalReleaseAssets(), deviceAbis['arm32 设备']!))!.name,
          'fushi-$version-armeabi-v7a.apk');
      expect(
          (await pick(formalReleaseAssets(), deviceAbis['x86_64 设备']!))!.name,
          'fushi-$version-x86_64.apk');
    });

    test('x86_64 设备真能拿到 x86_64 包（旧实现把 x86_64 改写成 x86-64，永不命中）', () async {
      expect(androidAssetMatchesAbi('fushi-$version-x86_64.apk', 'x86_64'),
          isTrue);
      expect((await pick(fushiAssets(), <String>['x86_64', 'x86']))!.name,
          'fushi-$version-x86_64.apk');
    });

    test('32 位 x86 设备不会拿到 x86_64 包（裸 contains 会误命中）', () async {
      expect(
          androidAssetMatchesAbi('fushi-$version-x86_64.apk', 'x86'), isFalse);
      expect(
          (await pick(
                  fushiAssets(), <String>['x86', 'armeabi-v7a', 'armeabi']))!
              .name,
          'fushi-$version-armeabi-v7a.apk');
    });

    test('资产倒序喂入不改变架构选择', () async {
      final List<String> reversed =
          formalReleaseAssets().reversed.toList(growable: false);
      expect((await pick(reversed, deviceAbis['arm64 设备']!))!.name,
          'fushi-$version-arm64-v8a.apk');
    });

    test('有分架构包但没有本机这一档 → 返回 null，不塞错架构', () async {
      expect(await pick(fushiAssets(), <String>['riscv64']), isNull);
    });

    test('取设备 ABI 失败（空列表）时同样返回 null 而不是列表首个', () async {
      // `_defaultAbis()` 在 DeviceInfoPlugin 抛异常时返回空列表。
      expect(await pick(fushiAssets(), <String>[]), isNull);
    });

    test('universal 单包（debug 通道）仍走兜底，不被上面的收紧误伤', () async {
      final UpdateAsset? picked = await AndroidUpdater(
        abiProvider: () async => <String>[],
      ).selectAsset(<Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'fushi-1.4.0-debug.10332-2cddfff-debug.apk',
          'browser_download_url': 'https://example.invalid/u.apk',
        },
      ], channel: UpdateChannel.debug);
      expect(picked!.name, 'fushi-1.4.0-debug.10332-2cddfff-debug.apk');
    });
  });
}
