import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';

/// BUG-1481 守卫：**自更新绝不选中别的产品族的资产**。
///
/// 改名过渡期同一个 GitHub 仓库里同时躺着三种资产名：本体 `fushi-*`、迁移桥包
/// `hibiki-*`（包名 `app.hibiki.reader`）、以及更早的无前缀历史产物。而挑包判据只看
/// 平台后缀（`.apk` / `-windows-setup.exe` / `-macos.zip`），三者一律命中。
///
/// 装错族的后果按平台不同但都不可接受：
/// * Android：包名 + 签名是安装身份的一部分，跨包名的 APK 系统直接拒
///   （`INSTALL_FAILED_UPDATE_INCOMPATIBLE`），侥幸装上也只是并存的第二个空 app。
/// * 桌面：安装器覆盖安装 —— 用户点「更新」，结果被降级成已退场的老产品。
///
/// 清单分族（`update_manifest_product_split_test.dart`）之后正常路径本就不会再拿到
/// 别族资产，但回退路径还在：manifest 三个镜像全挂时会直连
/// `api.github.com/.../releases?per_page=20`，那里是全仓库所有 release 的并集，
/// 混着两族。所以这层过滤是回退路径上的最后一道闸，不能因为「清单已经分开了」就删。
Map<String, dynamic> _asset(String name) => <String, dynamic>{
      'name': name,
      'browser_download_url': 'https://example.invalid/download/$name',
    };

void main() {
  group('assetBelongsToThisProduct（纯函数）', () {
    test('只认本族前缀', () {
      expect(assetBelongsToThisProduct('fushi-1.4.0-arm64-v8a.apk'), isTrue);
      expect(
          assetBelongsToThisProduct('fushi-1.4.0-windows-setup.exe'), isTrue);
    });

    test('拒绝桥包族与无前缀历史产物', () {
      expect(assetBelongsToThisProduct('hibiki-1.2.0-arm64-v8a.apk'), isFalse);
      expect(
          assetBelongsToThisProduct('hibiki-1.2.0-windows-setup.exe'), isFalse);
      expect(assetBelongsToThisProduct('hibiki-1.2.0-macos.zip'), isFalse);
      // 无前缀的更早期手动发布产物同样不是本族。
      expect(assetBelongsToThisProduct('app-arm64-v8a-release.apk'), isFalse);
    });

    test('不能靠子串蒙混：前缀必须在开头', () {
      expect(assetBelongsToThisProduct('hibiki-fushi-1.4.0-arm64-v8a.apk'),
          isFalse);
    });
  });

  group('selectAsset 在只有别族资产时必须一个都不选', () {
    test('Android：ABI 完全匹配的 hibiki APK 也不选', () async {
      final AndroidUpdater updater = AndroidUpdater(
        abiProvider: () async => <String>['arm64-v8a'],
      );
      final UpdateAsset? picked = await updater.selectAsset(
        <Map<String, dynamic>>[_asset('hibiki-1.2.0-arm64-v8a.apk')],
      );
      expect(picked, isNull, reason: '跨包名 APK 装不上，宁可不更新也不能选中');
    });

    test('Android：ABI 不匹配时的 fallback 也不许兜到别族', () async {
      final AndroidUpdater updater = AndroidUpdater(
        abiProvider: () async => <String>['x86_64'],
      );
      final UpdateAsset? picked = await updater.selectAsset(
        <Map<String, dynamic>>[_asset('hibiki-1.2.0-arm64-v8a.apk')],
      );
      expect(picked, isNull, reason: 'fallback 分支是最容易漏掉产品族判据的地方');
    });

    test('Windows：hibiki setup 不选', () async {
      final UpdateAsset? picked = await WindowsUpdater().selectAsset(
        <Map<String, dynamic>>[_asset('hibiki-1.2.0-windows-setup.exe')],
      );
      expect(picked, isNull, reason: '会把自己覆盖安装成已退场的老产品');
    });

    test('macOS：hibiki zip 不选', () async {
      final UpdateAsset? picked = await MacUpdater().selectAsset(
        <Map<String, dynamic>>[_asset('hibiki-1.2.0-macos.zip')],
      );
      expect(picked, isNull);
    });
  });

  group('两族混在同一个 release 里时挑本族', () {
    test('Android 跳过 hibiki APK 选中同 ABI 的 fushi APK', () async {
      final AndroidUpdater updater = AndroidUpdater(
        abiProvider: () async => <String>['arm64-v8a'],
      );
      final UpdateAsset? picked = await updater.selectAsset(
        <Map<String, dynamic>>[
          // 别族排在前面：顺序不能决定结果。
          _asset('hibiki-1.2.0-arm64-v8a.apk'),
          _asset('fushi-1.4.0-arm64-v8a.apk'),
        ],
      );
      expect(picked?.name, 'fushi-1.4.0-arm64-v8a.apk');
    });

    test('Windows 跳过 hibiki setup 选中 fushi setup', () async {
      final UpdateAsset? picked = await WindowsUpdater().selectAsset(
        <Map<String, dynamic>>[
          _asset('hibiki-1.2.0-windows-setup.exe'),
          _asset('fushi-1.4.0-windows-setup.exe'),
        ],
      );
      expect(picked?.name, 'fushi-1.4.0-windows-setup.exe');
    });

    test('debug 通道同样只在本族里挑', () async {
      final AndroidUpdater updater = AndroidUpdater(
        abiProvider: () async => <String>['arm64-v8a'],
      );
      final UpdateAsset? picked = await updater.selectAsset(
        <Map<String, dynamic>>[
          _asset('hibiki-1.2.0-abc1234-debug.apk'),
          _asset('fushi-1.4.0-debug.10332-2cddfff-debug.apk'),
        ],
        channel: UpdateChannel.debug,
      );
      expect(picked?.name, 'fushi-1.4.0-debug.10332-2cddfff-debug.apk');
    });
  });

  test('synthesizeStableAssetNames 合成的候选名必须全是本族', () {
    // 白名单是 fail-closed 的：CI 若改了资产命名而这里没跟上，自更新会静默停摆。
    // 把「合成名」与「本族判据」钉在一起，命名漂移当场红，而不是等用户更新不动。
    final List<String> names = synthesizeStableAssetNames('1.4.0');
    expect(names, isNotEmpty);
    for (final String name in names) {
      expect(
        assetBelongsToThisProduct(name),
        isTrue,
        reason: '$name 过不了本族判据——302 回退路径合成的候选名'
            '会被 selectAsset 全部滤掉，stable 自更新静默失效',
      );
    }
  });
}
