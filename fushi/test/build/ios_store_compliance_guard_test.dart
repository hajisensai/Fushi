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
          isAndroid: false,
        ),
        isFalse,
      );
      expect(
        ModuleId.downloads.availableOn(
          isWindows: false,
          isDesktop: false,
          isIOS: false,
          isAndroid: true,
        ),
        isTrue,
        reason:
            'Android 同为移动端，但不受商店限制——判据必须认 iOS 本身，'
            '不能退化成「非桌面」。',
      );
    });

    test('iOS 与 Android 的模块集合只差下载中心（外加 games 这一条技术例外）', () {
      for (final ModuleId module in ModuleId.values) {
        if (module == ModuleId.downloads) continue;
        // games 是**技术**例外，不是合规边界：Android 的 games 模块是串流接收端
        // （WebRTC 接收入口只接了 Android），iOS 没有这个接收端，所以两端结论
        // 不同。它不属于 StoreRestrictedCapability，别据此把它登记进合规边界。
        if (module == ModuleId.games) continue;
        expect(
          module.availableOn(
            isWindows: false,
            isDesktop: false,
            isIOS: true,
            isAndroid: false,
          ),
          module.availableOn(
            isWindows: false,
            isDesktop: false,
            isIOS: false,
            isAndroid: true,
          ),
          reason: '${module.name} 的可用性不该随 iOS 与否改变。',
        );
      }
      expect(
        ModuleId.games.availableOn(
          isWindows: false,
          isDesktop: false,
          isIOS: true,
          isAndroid: false,
        ),
        isFalse,
        reason: 'iOS 没有串流接收端，也没有 galgame hook。',
      );
      expect(
        ModuleId.games.availableOn(
          isWindows: false,
          isDesktop: false,
          isIOS: false,
          isAndroid: true,
        ),
        isTrue,
        reason: 'Android 的 games 是串流接收端的远端游戏库。',
      );
    });

    test('可见集合在 iOS 上滤掉下载中心（用户把开关打开也一样）', () {
      final ModuleVisibility ios = ModuleVisibility.all(
        isWindows: false,
        isDesktop: false,
        isIOS: true,
        isAndroid: false,
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
        isAndroid: true,
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

    test('「AI 下视频」入口 / 设置分类 / 功能指派行三处都过 downloads + '
        'externalDiscovery 两道门', () {
      // 对话页里说作品名 → 识别 → 下载或订阅：既是在线发现又是下载中心。三处消费
      // 点必须问同一对判据；其中功能指派行最容易漏——它不是入口也不是分类，只是
      // 设置页里一行文案，但那行写着「然后下载或订阅」，iOS 上留着等于把被拆掉
      // 的能力写在审核员眼前（PR #1592 审查补的就是这一处）。
      const String gates =
          'StoreRestrictedCapability.downloads.isAvailable&&'
          'StoreRestrictedCapability.externalDiscovery.isAvailable';

      // 首页入口：AI 已指派 + 两道门 + 运行时就绪。
      expect(
        compactCode(read('lib/src/pages/implementations/home_page.dart')),
        contains(
          'boolget_canAiAcquire=>appModelNoUpdate.isPreferencesReady&&'
          'resolveVideoAcquireAiProvider(appModelNoUpdate.prefsRepo)!=null&&'
          '$gates&&',
        ),
      );

      // 设置分类：section 级 visible，正文 / 主从详情 / 搜索索引三条路径共用。
      expect(
        compactCode(read('lib/src/settings/settings_schema_ai.dart')),
        contains(
          "id:'ai.video_download',title:t.ai_video_download_section,"
          'visible:(SettingsContextc)=>$gates&&'
          'c.appModel.moduleVisibility.isEnabled(ModuleId.downloads),',
        ),
      );

      // 功能指派行：AiFeature.values 逐行渲染前过滤。
      final String section = compactCode(
        read('lib/src/pages/implementations/ai_provider_settings_section.dart'),
      );
      expect(
        section,
        contains(
          'for(finalAiFeaturefeatureinAiFeature.values)'
          'if(_featureAvailableOnThisStore(feature))_featureRow(feature),',
        ),
      );
      expect(
        section,
        contains(
          'staticbool_featureAvailableOnThisStore(AiFeaturefeature)=>'
          'feature!=AiFeature.videoAcquire||($gates);',
        ),
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

    test('视频「导入」视图的在线源三段（Aniyomi）由 onlineVideoSource 门控', () {
      // 判据只写在 video_online_sources_gate.dart 一处（合规门 + 运行时平台门），
      // 导入页只问它——这条边界失效是静默的（本地与 CI 全绿、上架才被拒）。
      final String gate = compactCode(
        read('lib/src/media/video/online/video_online_sources_gate.dart'),
      );
      expect(
        gate,
        contains(
          'boolgetisVideoOnlineSourcesAvailable=>'
          'StoreRestrictedCapability.onlineVideoSource.isAvailable&&'
          'MihonRuntimeFactory.isSupported;',
        ),
      );
      final String sources = compactCode(
        read('lib/src/pages/implementations/media_sources_page.dart'),
      );
      expect(
        sources,
        contains("if(widget.mediaKind=='video'&&isVideoOnlineSourcesAvailable)"),
        reason: '视频导入页取 animeMihonManager（仓库 / 扩展 / 在线源三段）必须挂在这个门后。',
      );
      expect(
        sources,
        contains('if(animeManager!=null)...<Widget>['),
        reason: '三段的 sliver 只在拿到 manager 时才进树，门失效时整段不出现。',
      );
      expect(
        sources,
        isNot(contains('Platform.isIOS')),
        reason: '消费端不得各自写平台判断，只问 StoreRestrictedCapability。',
      );
    });

    test('书「导入」视图的小说源三段（LNReader）由 onlineNovelSource 门控', () {
      final String gate = compactCode(
        read('lib/src/media/novel/online/novel_online_sources_gate.dart'),
      );
      expect(
        gate,
        contains(
          'boolgetisNovelOnlineSourcesAvailable=>'
          'StoreRestrictedCapability.onlineNovelSource.isAvailable&&'
          'isLnReaderRuntimeSupported;',
        ),
      );
      expect(
        gate,
        isNot(contains('Platform.isIOS')),
        reason: '运行时平台门只列真支持的平台，iOS 的缺席归合规门管。',
      );
      final String sources = compactCode(
        read('lib/src/pages/implementations/media_sources_page.dart'),
      );
      expect(
        sources,
        contains("if(widget.mediaKind=='book'&&isNovelOnlineSourcesAvailable)"),
        reason: '书导入页取 lnReaderManager（仓库 / 扩展 / 在线源三段）必须挂在这个门后。',
      );
      expect(
        sources,
        contains('if(novelManager!=null)...<Widget>['),
        reason: '三段的 sliver 只在拿到 manager 时才进树，门失效时整段不出现。',
      );
      // 在线小说书的描述符会随备份恢复到 iOS：阅读器开书建取章加载器（它会拉起
      // lnReaderManager、联网刷仓库、跑插件）也必须挂在同一个门后。
      final String onlineBook = compactCode(
        read('lib/src/media/novel/online/lnreader_online_book.dart'),
      );
      expect(
        onlineBook,
        contains(
          'if(!(onlineSourcesAvailable??isNovelOnlineSourcesAvailable))'
          'returnnull;',
        ),
        reason: '阅读器开在线书时取 lnReaderManager 必须先过在线小说门。',
      );
    });
  });

  group('Aidoku 的 iOS 宿主已整条移除', () {
    test('Dart 工厂不认任何平台（macOS 宿主随后也已移除）', () {
      final String runtime = compactCode(
        read('lib/src/media/manga/aidoku/aidoku_runtime.dart'),
      );
      expect(runtime, contains('staticboolgetisSupported=>false;'));
      expect(
        runtime,
        isNot(contains('Platform.isIOS')),
        reason: 'iOS 分支必须消失，而不是留着抛异常——留着就还需要 native 侧配合。',
      );
      expect(
        runtime,
        isNot(contains('Platform.isMacOS')),
        reason:
            'macOS 子进程宿主随 Rust CLI、打包脚本与 CI 步骤一并移除；'
            '分支留着就是一条指向不存在 helper 的死路径。',
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

    test('macOS 侧的 Aidoku 宿主也已整条移除', () {
      // 曾是反向断言「不要顺手把 macOS 也删了」；macOS 宿主随后按同一口径移除，
      // 这里改钉新事实：Dart 侧没有子进程实现，两条 macOS workflow 也不再打
      // runtime 进 bundle，发布包里不带 WASM 解释器。
      expect(
        read('lib/src/media/manga/aidoku/aidoku_runtime.dart'),
        isNot(contains('DesktopAidokuRuntime')),
      );
      for (final String path in <String>[
        '../.github/workflows/build-multiplatform.yml',
        '../.github/workflows/release-desktop.yml',
      ]) {
        final String workflow = read(path);
        expect(workflow, isNot(contains('tool/aidoku/')));
        expect(workflow, isNot(contains('aidoku_runtime')));
        expect(
          workflow,
          isNot(contains('apple-darwin')),
          reason: '$path 里的 macOS Rust target 只为 Aidoku runtime 而装。',
        );
      }
      expect(Directory('../tool/aidoku').existsSync(), isFalse);
      expect(
        File('../native/aidoku_runtime/src/main.rs').existsSync(),
        isFalse,
      );
    });
  });
}
