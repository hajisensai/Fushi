import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:path/path.dart' as p;

/// **发 2.0 正式版的硬门**：formal release 的资产表必须让**已出货的 Hibiki v1.2.0**
/// 命中迁移桥包，而不是本体 Fushi。
///
/// 这一层守的不是本仓代码的行为，而是**改不了的外部二进制的行为**。v1.2.0 的挑包判据是
/// 「`.apk` 结尾 + 名字含设备 `SUPPORTED_ABIS` 任一项」，完全不认产品族（本体这侧的
/// [assetBelongsToThisProduct] 是 BUG-1481 之后才有的，救不了已经装在用户手机上的包）。
/// 2.0 正式版 release 上同时挂两族资产：
/// * `hibiki-<version>-<abi>.apk` —— 迁移桥包，旧包名 `app.hibiki.reader` + 旧签名
///   （实测 1.1.0 / 1.2.0 / 桥包的签名公钥同为 `d40c4a16…`），能原地覆盖升级，带迁移导出器。
/// * `fushi-<version>-<记号>.apk` —— 本体，新包名新签名。
///
/// 若本体也用 ABI 全名，老客户端会命中**字母序更靠前**的那个（实测 GitHub API 按文件名
/// 升序返回资产，`fushi-` < `hibiki-`），把跨包名的 Fushi 装成并存的第二个空 app；用户
/// 以为换代完成、卸掉 Hibiki，`/data/user/0/app.hibiki.reader/` 里的全部数据永久丢失。
///
/// 两个条件缺一不可，本文件把两个都钉死：
/// 1. 本体 formal 资产名**不含任何设备 ABI 串**（否则抢走 ABI 命中）；
/// 2. release 上**必须挂桥包**（否则老客户端退化成 `fallback ??= asset`，
///    「随便拿列表里第一个 apk」，照样装到本体上——光改名躲不掉）。
void main() {
  // ---------------------------------------------------------------------------
  // 已出货 v1.2.0 的挑包逻辑，从 tag `v1.2.0` 的 `platform_updater.dart`
  // （当年 app 目录还未改名）里 **逐字抄来**。
  //
  // 这是冻结的外部契约快照，不是本仓实现的镜像：**永远不要**把它「重构」成调用当前的
  // `AndroidUpdater`——那样这些用例就退化成自证，而它们要证的恰恰是「当前发布的资产表
  // 喂给一个我们再也改不动的旧二进制会发生什么」。
  // ---------------------------------------------------------------------------
  bool legacyIsDebugApkAsset(String name) =>
      name.endsWith('-debug.apk') || name.contains('-debug.');

  bool legacyMatchesStableChannel(String name) =>
      name.endsWith('.apk') && !legacyIsDebugApkAsset(name);

  String? legacySelectApk(List<String> assetNames, List<String> deviceAbis) {
    final List<String> abiTags =
        deviceAbis.map((String a) => a.replaceAll('_', '-')).toList();
    // GitHub API 按文件名升序返回资产（实测：created_at / id 均无序）。
    final List<String> ordered = List<String>.from(assetNames)..sort();
    String? fallback;
    for (final String name in ordered) {
      if (!legacyMatchesStableChannel(name)) continue;
      if (abiTags.any(name.contains)) return name;
      fallback ??= name;
    }
    return fallback;
  }

  const String version = '2.0.0';

  /// 2.0 正式版 release 上给老 Hibiki 的迁移桥包（旧包名 + 旧签名 + 迁移导出器）。
  const List<String> bridgeAssets = <String>[
    'hibiki-$version-arm64-v8a.apk',
    'hibiki-$version-armeabi-v7a.apk',
    'hibiki-$version-x86_64.apk',
  ];

  /// 一次 formal 发布挂在 release 上的完整资产表。
  List<String> formalReleaseAssets() => <String>[
        ...synthesizeStableAssetNames(version),
        ...bridgeAssets,
      ];

  /// 设备 `SUPPORTED_ABIS` 的真实取值（含 64 位设备同时上报的 32 位项）。
  const Map<String, List<String>> deviceAbis = <String, List<String>>{
    'arm64 设备': <String>['arm64-v8a', 'armeabi-v7a', 'armeabi'],
    'arm32 设备': <String>['armeabi-v7a', 'armeabi'],
    'x86_64 设备': <String>['x86_64', 'x86', 'armeabi-v7a', 'armeabi'],
  };

  /// 老客户端在各设备上实际会拿到的桥包。
  ///
  /// x86_64 那一行**不是** `-x86_64.apk`，这是 v1.2.0 自身的缺陷，不是我们发法的问题、
  /// 也修不了（二进制已出货）：它拿**资产列表**做外层循环（按文件名升序），命中任一设备
  /// ABI 就返回，于是字母序更靠前的 `armeabi-v7a` 先命中——x86_64 设备的
  /// `SUPPORTED_ABIS` 里本来就带 `armeabi-v7a`。同一个缺陷在改名之前就存在（当时是
  /// 在 `fushi-*`/`hibiki-*` 各自的 ABI 名之间选），本次改动既没引入也没放大它。
  ///
  /// 判定为可接受：x86_64 Android 只有模拟器 / Chromebook / 少量 x86 平板，且这些设备
  /// 上报 `armeabi-v7a` 就意味着有 ARM 翻译层；桥包唯一的职责是把数据导出来，跑在翻译层
  /// 上完全够用。真正致命的那条不变式——**绝不选中 `fushi-*`**——在三类设备上都成立，
  /// 由下面的用例分开断言。
  const Map<String, String> expectedBridgePick = <String, String>{
    'arm64 设备': 'hibiki-$version-arm64-v8a.apk',
    'arm32 设备': 'hibiki-$version-armeabi-v7a.apk',
    'x86_64 设备': 'hibiki-$version-armeabi-v7a.apk',
  };

  group('已出货 Hibiki v1.2.0 面对 2.0 正式版资产表', () {
    for (final MapEntry<String, List<String>> device in deviceAbis.entries) {
      test('${device.key}：命中本架构的迁移桥包', () {
        expect(
          legacySelectApk(formalReleaseAssets(), device.value),
          expectedBridgePick[device.key],
        );
      });

      test('${device.key}：绝不命中本体 Fushi 的 APK', () {
        final String? picked =
            legacySelectApk(formalReleaseAssets(), device.value);
        expect(
          picked!.startsWith('fushi-'),
          isFalse,
          reason: '跨包名装到 Fushi 上 = 并存空 app，用户卸旧包即永久丢数据；'
              '实际选中 $picked',
        );
      });
    }

    test('x86_64 设备落到 armeabi 桥包是 v1.2.0 自身的字母序缺陷，非本次发法所致', () {
      // 把桥包换成只有 ABI 名的「改名前发法」重跑：同样是 armeabi 先命中，证明这个
      // 顺序缺陷与本次记号化无关（当年选中的是 fushi-*-armeabi-v7a.apk）。
      const List<String> preRenameAssets = <String>[
        'fushi-$version-arm64-v8a.apk',
        'fushi-$version-armeabi-v7a.apk',
        'fushi-$version-x86_64.apk',
      ];
      expect(
        legacySelectApk(preRenameAssets, deviceAbis['x86_64 设备']!),
        'fushi-$version-armeabi-v7a.apk',
      );
    });

    test('桥包缺席时老客户端会兜底装到本体上——所以桥包资产不可省', () {
      // 反向用例：证明「只把 ABI 记号从本体资产名里拿掉」这条单独走不通。
      // 无 ABI 命中时 v1.2.0 退化成 `fallback ??= asset`（列表里第一个 apk）。
      final String? picked = legacySelectApk(
        synthesizeStableAssetNames(version),
        deviceAbis['arm64 设备']!,
      );
      expect(picked, isNotNull);
      expect(
        picked!.startsWith('fushi-'),
        isTrue,
        reason: '这正是必须同时挂桥包的原因：光改名挡不住老客户端',
      );
    });
  });

  group('formal 资产名不得含任何设备 ABI 串', () {
    // 老客户端拿 `SUPPORTED_ABIS` 原值（`_` 换 `-`）做**子串**匹配，本体资产名撞上
    // 其中任何一个都会把 ABI 命中从桥包手里抢走。
    const List<String> deviceAbiTags = <String>[
      'arm64-v8a',
      'armeabi-v7a',
      'armeabi',
      'x86',
      'x86-64',
      'riscv64',
    ];

    test('synthesizeStableAssetNames 合成的 APK 名干净', () {
      final Iterable<String> apks = synthesizeStableAssetNames(version)
          .where((String n) => n.endsWith('.apk'));
      expect(apks, isNotEmpty);
      for (final String name in apks) {
        for (final String abi in deviceAbiTags) {
          expect(name.contains(abi), isFalse,
              reason: '$name 含设备 ABI 串 $abi，会抢走桥包的 ABI 命中');
        }
      }
    });

    test('记号表本身覆盖 CI 会产出的全部 split ABI', () {
      expect(kAndroidStableAbiTokens.keys, containsAll(kAndroidReleaseAbis));
      for (final String token in kAndroidStableAbiTokens.values) {
        for (final String abi in deviceAbiTags) {
          expect(token.contains(abi), isFalse);
        }
      }
    });
  });

  group('本体自己仍然挑得对（记号 + 产品族）', () {
    const Map<String, String> expectedSelfPick = <String, String>{
      'arm64 设备': 'fushi-$version-a64.apk',
      'arm32 设备': 'fushi-$version-a32.apk',
      'x86_64 设备': 'fushi-$version-x64.apk',
    };

    for (final MapEntry<String, List<String>> device in deviceAbis.entries) {
      test('${device.key}：挑到本架构的 fushi 包，桥包在场也不选', () async {
        final AndroidUpdater updater =
            AndroidUpdater(abiProvider: () async => device.value);
        final UpdateAsset? picked =
            await updater.selectAsset(<Map<String, dynamic>>[
          for (final String name in formalReleaseAssets())
            <String, dynamic>{
              'name': name,
              'browser_download_url': 'https://example.invalid/$name',
            },
        ]);
        expect(picked, isNotNull);
        expect(picked!.name, expectedSelfPick[device.key]);
      });
    }

    test('架构选择不受资产字母序影响（-a32 排在 -a64 前面）', () async {
      // 倒序喂进去，64 位设备仍须拿到 a64：ABI 偏好顺序才是决策依据。
      final AndroidUpdater updater = AndroidUpdater(
        abiProvider: () async => deviceAbis['arm64 设备']!,
      );
      final List<String> reversed =
          formalReleaseAssets().reversed.toList(growable: false);
      final UpdateAsset? picked =
          await updater.selectAsset(<Map<String, dynamic>>[
        for (final String name in reversed)
          <String, dynamic>{
            'name': name,
            'browser_download_url': 'https://example.invalid/$name',
          },
      ]);
      expect(picked!.name, 'fushi-$version-a64.apk');
    });

    test('记号不做子串匹配：版本串里出现 a64 不算命中', () async {
      final AndroidUpdater updater = AndroidUpdater(
        abiProvider: () async => <String>['arm64-v8a'],
      );
      final UpdateAsset? picked =
          await updater.selectAsset(<Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'fushi-2.0.0-a64beta.apk',
          'browser_download_url': 'https://example.invalid/x.apk',
        },
      ]);
      // 唯一候选，只能走 universal fallback；重点是它**不是**按 ABI 命中的。
      expect(androidAssetMatchesAbi('fushi-2.0.0-a64beta.apk', 'arm64-v8a'),
          isFalse);
      expect(picked!.name, 'fushi-2.0.0-a64beta.apk');
    });
  });

  group('CI 与客户端两侧命名逐字一致', () {
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

    test('formal 分支的记号表与 kAndroidStableAbiTokens 一一对上', () {
      for (final MapEntry<String, String> e
          in kAndroidStableAbiTokens.entries) {
        expect(
          RegExp('${RegExp.escape(e.key)}\\)\\s*echo ${e.value}\\s*;;')
              .hasMatch(workflow),
          isTrue,
          reason: 'release.yml 的 abi_asset_tag 缺 ${e.key} -> ${e.value}',
        );
      }
    });

    test('只有 formal 通道换记号，beta/debug 保持 ABI 全名', () {
      expect(
        workflow.contains(
            r'if [ "${{ steps.channel.outputs.manifest_channel }}" = "formal" ]; then'),
        isTrue,
        reason: '记号命名必须只作用于 formal——在野旧 Fushi 客户端按 ABI 全名挑 beta/debug 包',
      );
      expect(workflow.contains(r'ASSET_ABI="$ABI"'), isTrue,
          reason: '非 formal 通道必须原样使用 ABI 全名');
      expect(
          workflow.contains(
              r'cp "$f" "$OUT_DIR/fushi-${BUILD_VERSION_NAME}-${ASSET_ABI}.apk"'),
          isTrue);
    });
  });
}
