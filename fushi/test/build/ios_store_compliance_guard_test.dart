import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';

import '../helpers/source_guard.dart';

/// iOS 版按 App Store 审核指南剔除三类能力：内置外部发现源与各库页的发现视图、
/// 在线漫画源宿主（Aidoku / Mihon / mokuro.moe）、下载中心。
///
/// 这组守卫钉的是**合规边界不会被悄悄改回来**。它比一般的行为测试更需要存在，
/// 因为这条边界的失效是**静默**的：漏掉任何一处，本地五个平台照样全绿、CI 照样
/// 全绿，代价要等到上架被拒才出现，而被拒的那一处从代码里根本看不出它本该属于
/// 这条边界。所以判据两侧都要断言——Dart 判据一侧（下面第一组），以及每个消费点
/// 确实问了那个判据（后面几组，源码扫描）。
///
/// iOS 原生侧单独一组：Aidoku 的 iOS 宿主是**内嵌 Rust 静态库**（WASM 解释器），
/// 光把 Dart 工厂关掉、二进制里仍然带着它，是最容易在审核里翻车的那种残留。
void main() {
  String read(String relativeToFushi) {
    final File file = File(relativeToFushi);
    expect(
      file.existsSync(),
      isTrue,
      reason: 'expected file at ${file.absolute.path}',
    );
    return file.readAsStringSync();
  }

  group('合规判据本身', () {
    test('三类受限能力在 iOS 上一律缺席，其余平台一律存在', () {
      for (final StoreRestrictedCapability capability
          in StoreRestrictedCapability.values) {
        expect(
          capability.availableOn(isIOS: true),
          isFalse,
          reason: '${capability.name} 在 iOS 上必须不存在。',
        );
        expect(
          capability.availableOn(isIOS: false),
          isTrue,
          reason:
              '${capability.name} 只对 iOS 关闭，'
              '其余平台不走商店分发，不受这条边界约束。',
        );
      }
    });

    test('下载中心在 iOS 上不是一个可用模块', () {
      expect(
        ModuleId.downloads.availableOn(
          isWindows: false,
          isDesktop: false,
          isIOS: true,
        ),
        isFalse,
      );
      expect(
        ModuleId.downloads.availableOn(
          isWindows: false,
          isDesktop: false,
          isIOS: false,
        ),
        isTrue,
        reason:
            'Android 同为移动端，但不受商店限制——判据必须认 iOS 本身，'
            '不能退化成「非桌面」。',
      );
    });

    test('iOS 这个维度只动下载中心，不误伤其它模块', () {
      for (final ModuleId module in ModuleId.values) {
        if (module == ModuleId.downloads) continue;
        expect(
          module.availableOn(isWindows: false, isDesktop: false, isIOS: true),
          module.availableOn(isWindows: false, isDesktop: false, isIOS: false),
          reason: '${module.name} 的可用性不该随 iOS 与否改变。',
        );
      }
    });

    test('可见集合在 iOS 上滤掉下载中心（用户把开关打开也一样）', () {
      final ModuleVisibility ios = ModuleVisibility.all(
        isWindows: false,
        isDesktop: false,
        isIOS: true,
      );
      expect(ios.isEnabled(ModuleId.downloads), isFalse);
      expect(
        ios.isEnabled(ModuleId.manga),
        isTrue,
        reason: '漫画库本身保留：iOS 上关掉的是在线源，不是本地漫画阅读。',
      );

      final ModuleVisibility android = ModuleVisibility.all(
        isWindows: false,
        isDesktop: false,
        isIOS: false,
      );
      expect(android.isEnabled(ModuleId.downloads), isTrue);
    });
  });

  group('发现入口全部过同一道门', () {
    test('书 / 漫画 / 视频三个库页的发现视图都由 externalDiscovery 门控', () {
      const String gate =
          'if(StoreRestrictedCapability.externalDiscovery.isAvailable)';

      // 书 tab：统一发现页（小说 + 有声书在线源）。
      expect(
        compactCode(
          read('lib/src/pages/implementations/home_reader_page.dart'),
        ),
        contains(
          '${gate}MediaLibraryViewSpec(kind:MediaLibraryViewKind.browse,',
        ),
      );

      // 漫画 tab：AniList 榜单 + 各来源热门行 + mokuro.moe 卷下载。
      expect(
        compactCode(read('lib/src/media/manga/manga_library_page.dart')),
        contains(
          '${gate}MediaLibraryViewSpec(kind:MediaLibraryViewKind.discover,',
        ),
      );

      // 视频 tab：番剧发现 → 资源索引器 → 种子获取。
      expect(
        compactCode(
          read('lib/src/pages/implementations/video_library_shell.dart'),
        ),
        contains(
          '${gate}LibrarySectionTab<VideoLibrarySection>'
          '(value:VideoLibrarySection.discover,',
        ),
      );
    });

    test('发现源注册表在 iOS 上一个源都不登记', () {
      // 判据落在建注册表的那一处，而不是各个源自己判——源是列表字面量里的元素，
      // 逐个加判据只要漏掉一个就是漏掉一整个内容索引站。
      final String appModel = compactCode(
        read('lib/src/models/app_model.dart'),
      );
      expect(
        appModel,
        contains(
          'if(!StoreRestrictedCapability.externalDiscovery.isAvailable){'
          'return_mediaDiscoveryService=MediaDiscoveryService('
          'sources:const<MediaDiscoverySource>[],);}',
        ),
        reason: '空注册表必须在内置源列表**之前**返回。',
      );
    });

    test('视频域的发现 provider 过门，元数据 provider 不过门', () {
      final String source = compactCode(
        read('lib/src/media/video/discovery/video_discovery_service.dart'),
      );
      expect(
        source,
        contains(
          'finalbooldiscoveryAvailable='
          'StoreRestrictedCapability.externalDiscovery.isAvailable;',
        ),
      );
      expect(
        source,
        contains('if(discoveryAvailable)AniListVideoDiscoveryProvider(),'),
      );
      // 刮削链路（给已入库文件补作品资料）与「站上有什么可看」不是一回事，
      // 两者共用本类只是因为查的是同一批 API。门错了会把刮削一起关掉。
      expect(
        source,
        contains(
          'metadataProviders:<VideoMetadataProvider>[...catalog.providers,anilist,],',
        ),
        reason: 'metadata provider 不受发现门约束。',
      );
    });

    test('设置里的资源索引器分区在 iOS 上整节不渲染', () {
      expect(
        compactCode(read('lib/src/settings/settings_schema_services.dart')),
        contains(
          "id:'services.resources',title:t.section_services_resources,"
          'visible:(_)=>StoreRestrictedCapability.externalDiscovery.isAvailable,',
        ),
        reason:
            '用 section 级 visible：分类正文 / 主从详情 / 设置搜索索引 '
            '三条渲染路径共用它，逐项写会漏掉搜索索引。',
      );
    });

    test('漫画「来源」视图的在线源三节由 onlineMangaSource 门控', () {
      final String source = compactCode(
        read('lib/src/media/manga/manga_sources_page.dart'),
      );
      expect(
        source,
        contains(
          'finalboolonlineSourcesAvailable='
          'StoreRestrictedCapability.onlineMangaSource.isAvailable;',
        ),
      );
      expect(source, contains('if(onlineSourcesAvailable)'));
      expect(
        source,
        contains('if(onlineSourcesAvailable&&manager!=null)'),
        reason: 'Mihon 扩展提供的源行也在这节里，不能只挡住标题。',
      );
    });
  });

  group('Aidoku 的 iOS 宿主已整条移除', () {
    test('Dart 工厂只认 macOS', () {
      final String runtime = compactCode(
        read('lib/src/media/manga/aidoku/aidoku_runtime.dart'),
      );
      expect(runtime, contains('staticboolgetisSupported=>Platform.isMacOS;'));
      expect(
        runtime,
        isNot(contains('Platform.isIOS')),
        reason: 'iOS 分支必须消失，而不是留着抛异常——留着就还需要 native 侧配合。',
      );
      expect(
        runtime,
        isNot(contains('classIosAidokuRuntime')),
        reason:
            'MethodChannel 实现随 native 一起删；留着就是一条指向不存在 '
            'handler 的死路径。',
      );
    });

    test('iOS 原生侧不再构建 / 链接 / 桥接 Aidoku runtime', () {
      final String pbxproj = read('ios/Runner.xcodeproj/project.pbxproj');
      expect(
        pbxproj.toLowerCase(),
        isNot(contains('aidoku')),
        reason:
            'build phase、AIDOKU_RUNTIME_* 变量与链接输入必须一并消失；'
            '只删 build phase 会留下一个链不到东西的 archive 输入。',
      );

      expect(
        read('ios/Runner/AppDelegate.swift').toLowerCase(),
        isNot(contains('aidoku')),
      );
      expect(
        read('ios/Runner/Runner-Bridging-Header.h'),
        isNot(contains('fushi_aidoku')),
      );
      expect(
        File('ios/build_aidoku_runtime.sh').existsSync(),
        isFalse,
        reason:
            '构建脚本留着，下一个人只要在 pbxproj 里加回一条 build phase '
            '就能把解释器重新塞进包里。',
      );
    });

    test('CI 不再为 iOS 装 Rust target', () {
      for (final String path in <String>[
        '../.github/workflows/build-multiplatform.yml',
        '../.github/workflows/release-desktop.yml',
      ]) {
        expect(
          read(path),
          isNot(contains('aarch64-apple-ios')),
          reason: '$path 里的 iOS Rust toolchain 只为 Aidoku runtime 而装。',
        );
      }
    });

    test('macOS 侧的 Aidoku 打包不受影响', () {
      // 反向断言：这次移除的是 iOS 宿主，macOS 仍然是受支持平台。两条 macOS
      // workflow 的打包步骤见 macos_aidoku_runtime_packaging_guard_test.dart，
      // 这里只钉「不要顺手把 macOS 也删了」。
      expect(
        read('lib/src/media/manga/aidoku/aidoku_runtime.dart'),
        contains('DesktopAidokuRuntime'),
      );
      expect(
        read('../.github/workflows/release-desktop.yml'),
        contains('tool/aidoku/build_macos_runtime.sh'),
      );
    });
  });
}
