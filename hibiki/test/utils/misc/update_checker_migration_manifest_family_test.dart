import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

/// BUG-1481 守卫：一键迁移取包必须读 **Fushi 族**的镜像清单。
///
/// 背景（这条链断过一次）：改名过渡期一个仓库出两个产品，桥包
/// （`app.hibiki.reader`，资产 `hibiki-*`）与 Fushi（`app.fushi.reader`，资产
/// `fushi-*`）原本挂在同一个 rolling release / 同一份 `latest-<channel>.json` 上，
/// 所以迁移取包只要在 `selectAsset` 里按 [ReleaseProduct.fushi] 过滤就够。
/// BUG-1481 把清单按产品族拆成两个文件之后，本族清单里**再也没有** `fushi-*`
/// 资产——而 `_fetchReleasesForExactChannel` 命中清单后会 short-circuit、不回退
/// `api.github.com`，于是 `resolveMigrationTargetAsset` 恒返 null，用户点「迁移到
/// Fushi」永远停在「找不到 Fushi 产物」。
///
/// 契约两段，各自钉住：
/// 1. 清单文件名的键是「产品族 × 通道」，Fushi 族带 `-fushi` 后缀，本族冻结名不许动；
/// 2. `resolveMigrationTargetAsset` 必须把 [ReleaseProduct.fushi] 传给**拉取**层，
///    而不是只传给选包层。
void main() {
  group('BUG-1481 迁移取包读 Fushi 族清单', () {
    test('清单文件名按「产品族 × 通道」分，本族冻结名不变', () {
      // 本族（桥自己）：三条冻结名，已发出去的老客户端编译死了这些 URL。
      expect(manifestFileForChannel(UpdateChannel.debug), 'latest-debug.json');
      expect(manifestFileForChannel(UpdateChannel.beta), 'latest-beta.json');
      expect(
          manifestFileForChannel(UpdateChannel.stable), 'latest-stable.json');

      // Fushi 族：同一分支上另开一份，后缀与发布侧 MANIFEST_PRODUCT_SUFFIX 一致。
      expect(
        manifestFileForChannel(UpdateChannel.debug,
            product: ReleaseProduct.fushi),
        'latest-debug-fushi.json',
      );
      expect(
        manifestFileForChannel(UpdateChannel.beta,
            product: ReleaseProduct.fushi),
        'latest-beta-fushi.json',
      );
      expect(
        manifestFileForChannel(UpdateChannel.stable,
            product: ReleaseProduct.fushi),
        'latest-stable-fushi.json',
      );

      // any/own 都是本族：「不按产品族过滤」说的是选包，不是去读别人家的清单。
      expect(
        manifestFileForChannel(UpdateChannel.debug,
            product: ReleaseProduct.any),
        'latest-debug.json',
      );
    });

    test('URL 构造对每个镜像仓库都带上族后缀，且本族输出与冻结常量逐字节一致', () {
      final Map<String, String> own =
          manifestUrlsForChannel(UpdateChannel.debug);
      expect(own[kGitHubRepo], kDebugManifestUrl);
      expect(own[kLegacyGitHubRepo], kLegacyDebugManifestUrl);

      final Map<String, String> fushi = manifestUrlsForChannel(
        UpdateChannel.debug,
        product: ReleaseProduct.fushi,
      );
      expect(fushi.keys, containsAll(kGitHubRepoFallbacks));
      for (final String url in fushi.values) {
        expect(url, endsWith('/update-manifest/latest-debug-fushi.json'),
            reason: '镜像回退的每个仓库都必须指向 Fushi 族的清单，漏一个就是随机取到空清单');
      }
    });

    test('resolveMigrationTargetAsset 把产品族传给拉取层，不是只传给选包层', () {
      // 这一段没有可注入的网络缝（取包直接 new HttpClient），故用源码扫描钉住调用形状：
      // 只要有人把 product 从 _fetchReleasesForChannel 上摘掉、退回「只在 selectAsset
      // 过滤」，这条就红。
      final String source =
          File('lib/src/utils/misc/update_checker_migration.dart')
              .readAsStringSync();
      expect(
        source,
        contains('_fetchReleasesForChannel(client, channel,\n'
            '            product: ReleaseProduct.fushi)'),
        reason: '迁移取包必须显式读 Fushi 族清单；只在 selectAsset 过滤会把本族清单滤空、恒返 null',
      );
      expect(source, contains('product: ReleaseProduct.fushi,'),
          reason: '选包层的产品族硬约束仍要在（防止退化成「装桥包自己」）');
    });
  });
}
