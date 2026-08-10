import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/migration/migration_prompt.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';

/// 改名过渡期，桥包（`hibiki-*`）与 Fushi（`fushi-*`）的产物**挂在同一个 rolling
/// release tag 上**。这批测试锁死「两族永不互串」——串了的后果是真装不上
/// （签名不同，系统直接拒），或者用户点「迁移」结果装了桥包自己。
void main() {
  Map<String, dynamic> asset(String name) => <String, dynamic>{
        'name': name,
        'browser_download_url': 'https://example.invalid/$name',
      };

  // 同一个 debug-rolling release 上的真实资产形态。
  final List<Map<String, dynamic>> mixedDebugAssets = <Map<String, dynamic>>[
    asset('hibiki-1.3.2-debug.10182-arm64-v8a.apk'),
    asset('hibiki-1.3.2-debug.10182-armeabi-v7a.apk'),
    asset('fushi-1.4.0-debug.10302-arm64-v8a.apk'),
    asset('fushi-1.4.0-debug.10302-armeabi-v7a.apk'),
    asset('hibiki-1.3.2-debug.10182-windows-setup.exe'),
    asset('fushi-1.4.0-debug.10302-windows-setup.exe'),
    asset('fushi-1.4.0-debug.10302-macos.zip'),
  ];

  AndroidUpdater androidOn(String abi) =>
      AndroidUpdater(abiProvider: () async => <String>[abi]);

  group('assetBelongsToProduct', () {
    test('fushi 约束要求前缀命中', () {
      expect(
          assetBelongsToProduct(
              'fushi-1.4.0-arm64-v8a.apk', ReleaseProduct.fushi),
          isTrue);
      expect(
          assetBelongsToProduct(
              'hibiki-1.3.2-arm64-v8a.apk', ReleaseProduct.fushi),
          isFalse);
    });

    test('any 不加任何过滤（桌面自更新语义必须字节级不变）', () {
      // 桥的 stable 路径**有意**把桌面自更新指向 fushi-*（Phase 5），
      // 且历史手动发布的资产不保证带任何产品前缀 —— 两者都不能被过滤掉。
      for (final String name in <String>[
        'hibiki-1.3.2-arm64-v8a.apk',
        'fushi-1.4.0-arm64-v8a.apk',
        'app-arm64-v8a-release.apk',
      ]) {
        expect(assetBelongsToProduct(name, ReleaseProduct.any), isTrue,
            reason: '$name 不该被 any 过滤掉');
      }
    });

    test('own 只排除 fushi 族，不做 hibiki- 白名单', () {
      // 判据必须是「不是 fushi」而不是「以 hibiki- 开头」：历史手动发布的资产
      // 不带任何产品前缀，白名单会把它们全过滤掉＝掐断既有更新链路。
      expect(
          assetBelongsToProduct(
              'fushi-1.4.0-arm64-v8a.apk', ReleaseProduct.own),
          isFalse);
      expect(
          assetBelongsToProduct(
              'hibiki-1.3.2-arm64-v8a.apk', ReleaseProduct.own),
          isTrue);
      expect(
          assetBelongsToProduct(
              'app-arm64-v8a-release.apk', ReleaseProduct.own),
          isTrue,
          reason: '无产品前缀的历史资产不能被 own 误杀');
    });
  });

  group('AndroidUpdater.selectAsset 产品族隔离', () {
    test('自更新按 ABI 命中桥包自己', () async {
      final UpdateAsset? picked = await androidOn('arm64-v8a').selectAsset(
        mixedDebugAssets,
        channel: UpdateChannel.debug,
      );
      expect(picked, isNotNull);
      expect(picked!.name, 'hibiki-1.3.2-debug.10182-arm64-v8a.apk');
    });

    test('自更新绝不选中 fushi-*.apk —— 哪怕它在清单里排第一', () async {
      // 平台硬约束：跨包名+跨签名装不上（INSTALL_FAILED_UPDATE_INCOMPATIBLE）。
      // 桌面的 any 语义（Phase 5 有意指向 Fushi）在安卓上必须被收窄成 own，
      // 且是在 AndroidUpdater 内部收窄——调用方不传 product 也不能装错包。
      final UpdateAsset? picked = await androidOn('arm64-v8a').selectAsset(
        <Map<String, dynamic>>[
          asset('fushi-1.4.0-debug.10302-arm64-v8a.apk'),
          asset('hibiki-1.3.2-debug.10182-arm64-v8a.apk'),
        ],
        channel: UpdateChannel.debug,
      );
      expect(picked, isNotNull);
      expect(picked!.name, 'hibiki-1.3.2-debug.10182-arm64-v8a.apk');
    });

    test('自更新的 ABI fallback 也不许跨族兜底', () async {
      // fallback 是「ABI 全落空时退而求其次」，最容易漏掉产品族约束——
      // 漏了就是「设备 ABI 不在清单里 → 兜底装了 Fushi → 装失败」。
      final UpdateAsset? picked = await androidOn('riscv64').selectAsset(
        <Map<String, dynamic>>[
          asset('fushi-1.4.0-debug.10302-arm64-v8a.apk'),
          asset('hibiki-1.3.2-debug.10182-armeabi-v7a.apk'),
        ],
        channel: UpdateChannel.debug,
      );
      expect(picked, isNotNull);
      expect(picked!.name, startsWith('hibiki-'));
    });

    test('只有 Fushi 包时自更新返回 null（回退发布页），而不是给个装不上的包', () async {
      final UpdateAsset? picked = await androidOn('arm64-v8a').selectAsset(
        <Map<String, dynamic>>[
          asset('fushi-1.4.0-debug.10302-arm64-v8a.apk'),
          asset('fushi-1.4.0-debug.10302-armeabi-v7a.apk'),
        ],
        channel: UpdateChannel.debug,
      );
      expect(picked, isNull);
    });

    test('迁移下载绝不选中 hibiki-*.apk（否则桥包把自己当 Fushi 装）', () async {
      final UpdateAsset? picked = await androidOn('arm64-v8a').selectAsset(
        mixedDebugAssets,
        channel: UpdateChannel.debug,
        product: ReleaseProduct.fushi,
      );
      expect(picked, isNotNull);
      expect(picked!.name, 'fushi-1.4.0-debug.10302-arm64-v8a.apk');
    });

    test('ABI 不匹配时的 fallback 也受产品族约束', () async {
      // 设备 ABI 在清单里没有 → 走 fallback（第一个同族同通道包），
      // fallback 也绝不能跨族。
      final UpdateAsset? picked = await androidOn('riscv64').selectAsset(
        mixedDebugAssets,
        channel: UpdateChannel.debug,
        product: ReleaseProduct.fushi,
      );
      expect(picked, isNotNull);
      expect(picked!.name, startsWith('fushi-'));
    });

    test('只有桥包资产时，迁移解析返回 null 而非退化成装桥包自己', () async {
      final UpdateAsset? picked = await androidOn('arm64-v8a').selectAsset(
        <Map<String, dynamic>>[
          asset('hibiki-1.3.2-debug.10182-arm64-v8a.apk'),
        ],
        channel: UpdateChannel.debug,
        product: ReleaseProduct.fushi,
      );
      expect(picked, isNull);
    });

    test('真实 debug-rolling 资产名（通用包，名字里没有 ABI 标签）也能解析出来', () async {
      // 2026-08-08 debug-rolling 上的真实形态：Fushi debug 走单个通用 APK，
      // 不是 split-per-abi，所以名字里**没有** arm64-v8a 之类的标签。按 ABI 命中
      // 会落空，必须靠 fallback 兜住 —— 这条锁死「用户真按下去时确实能选到包」。
      final List<Map<String, dynamic>> realAssets = <Map<String, dynamic>>[
        asset('fushi-1.3.2-debug.10182-ios.ipa'),
        asset('fushi-1.4.0-debug.10301-b7a83ba-debug.apk'),
        asset('fushi-1.4.0-debug.10302-windows-setup.exe'),
        asset('hibiki-1.3.2-debug.10182-d863f0c-debug.apk'),
      ];
      final UpdateAsset? picked = await androidOn('arm64-v8a').selectAsset(
        realAssets,
        channel: UpdateChannel.debug,
        product: ReleaseProduct.fushi,
      );
      expect(picked, isNotNull, reason: '真实资产清单必须能解析出 Fushi 安装包');
      expect(picked!.name, 'fushi-1.4.0-debug.10301-b7a83ba-debug.apk');
    });

    test('产品族过滤不放过通道过滤（debug 族不会被 stable 选中）', () async {
      final UpdateAsset? picked = await androidOn('arm64-v8a').selectAsset(
        mixedDebugAssets,
        channel: UpdateChannel.stable,
        product: ReleaseProduct.fushi,
      );
      expect(picked, isNull, reason: '清单里 fushi 包全是 -debug.，stable 不该选中');
    });
  });

  group('WindowsUpdater / MacUpdater', () {
    test('Windows 迁移侧只认 fushi setup；自更新侧维持既有顺序语义', () async {
      final WindowsUpdater updater = WindowsUpdater();
      final UpdateAsset? target = await updater.selectAsset(mixedDebugAssets,
          channel: UpdateChannel.debug, product: ReleaseProduct.fushi);
      expect(target!.name, 'fushi-1.4.0-debug.10302-windows-setup.exe');
      final UpdateAsset? own = await updater.selectAsset(mixedDebugAssets,
          channel: UpdateChannel.debug);
      expect(own!.name, 'hibiki-1.3.2-debug.10182-windows-setup.exe');
    });

    test('macOS 自更新仍能选中 fushi zip —— 桥的 Phase 5 设计，不得被产品族过滤掐掉', () async {
      final UpdateAsset? own = await MacUpdater().selectAsset(
        mixedDebugAssets,
        channel: UpdateChannel.debug,
      );
      expect(own, isNotNull);
      expect(own!.name, 'fushi-1.4.0-debug.10302-macos.zip');
    });
  });

  group('shouldShowMigrationPrompt', () {
    test('未迁移的 Android 首次启动要弹', () {
      expect(
        shouldShowMigrationPrompt(
          migrated: false,
          isAndroid: true,
          alreadyShownThisLaunch: false,
          fushiInstalled: false,
        ),
        isTrue,
      );
    });

    test('已迁移且 Fushi 还在 → 不再打扰（首页常驻横幅接手）', () {
      expect(
        shouldShowMigrationPrompt(
          migrated: true,
          isAndroid: true,
          alreadyShownThisLaunch: false,
          fushiInstalled: true,
        ),
        isFalse,
      );
    });

    test('BUG-1501：已迁移但 Fushi 被卸了 → 必须弹（旧版只读 + 新版不存在＝两头落空）', () {
      expect(
        shouldShowMigrationPrompt(
          migrated: true,
          isAndroid: true,
          alreadyShownThisLaunch: false,
          fushiInstalled: false,
        ),
        isTrue,
      );
    });

    test('非 Android 不弹（跨包名迁移只存在于 Android）', () {
      expect(
        shouldShowMigrationPrompt(
          migrated: false,
          isAndroid: false,
          alreadyShownThisLaunch: false,
          fushiInstalled: false,
        ),
        isFalse,
      );
    });

    test('本进程弹过就不再弹（否则点「稍后」后立刻重弹＝用不了 app）', () {
      expect(
        shouldShowMigrationPrompt(
          migrated: false,
          isAndroid: true,
          alreadyShownThisLaunch: true,
          fushiInstalled: false,
        ),
        isFalse,
      );
    });
  });
}
