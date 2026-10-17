import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';

import '../helpers/source_guard.dart';

/// iOS 版按 App Store 审核指南剔除三类能力：内置外部发现源与各库页的发现视图、
/// 在线漫画源宿主（Mihon / mokuro.moe）、下载中心。
///
/// 这组守卫钉的是**合规边界不会被悄悄改回来**。它比一般的行为测试更需要存在，
/// 因为这条边界的失效是**静默**的：漏掉任何一处，本地五个平台照样全绿、CI 照样
/// 全绿，代价要等到上架被拒才出现，而被拒的那一处从代码里根本看不出它本该属于
/// 这条边界。所以判据两侧都要断言——Dart 判据一侧（下面第一组），以及每个消费点
/// 确实问了那个判据（后面几组，源码扫描）。
///
/// iOS 原生侧单独一组：已移除的 Aidoku 的 iOS 宿主曾是**内嵌 Rust 静态库**（WASM
/// 解释器），光把 Dart 工厂关掉、二进制里仍然带着它，是最容易在审核里翻车的那种
/// 残留；Aidoku 现已从本仓整体移除，那组守卫钉住它不会被加回来。
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
        ModuleId.browse.availableOn(
          isWindows: false,
          isDesktop: false,
          isIOS: true,
          isAndroid: false,
        ),
        isFalse,
      );
      expect(
        ModuleId.browse.availableOn(
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

    test('iOS 与 Android 的模块集合只差下载中心', () {
      for (final ModuleId module in ModuleId.values) {
        if (module == ModuleId.browse) continue;
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
      // 串流接收（从自己的电脑串流游戏，同类如 Steam Link / Moonlight）不在
      // 合规边界里：iOS 与 Android 的 games 同为串流接收端。
      expect(
        GamesModuleForm.on(isWindows: false),
        GamesModuleForm.streamClient,
      );
    });

    test('可见集合在 iOS 上滤掉下载中心（用户把开关打开也一样）', () {
      final ModuleVisibility ios = ModuleVisibility.all(
        isWindows: false,
        isDesktop: false,
        isIOS: true,
        isAndroid: false,
      );
      expect(ios.isEnabled(ModuleId.browse), isFalse);
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
      expect(android.isEnabled(ModuleId.browse), isTrue);
    });
  });

  group('发现入口全部过同一道门', () {
    test('库页的发现 / 来源 / 扩展子标签都挂在合规门后，浏览整模块过 downloads 门', () {
      // 2026-09-27 在线发现与来源 / 扩展搬进顶层「浏览」模块；2026-10-01 用户拍板
      // 浏览保留、同时把它们加回四个库页的子标签。库页里的每一个在线入口都必须
      // 自己过门——库模块本身在 iOS 上是开着的，漏门就是上架被拒。
      final String reader = compactCode(
        read('lib/src/pages/implementations/home_reader_page.dart'),
      );
      expect(
        reader,
        contains(
          'if(StoreRestrictedCapability.externalDiscovery.isAvailable)'
          'MediaLibraryViewSpec(kind:MediaLibraryViewKind.discover,',
        ),
        reason: '书架「发现」视图必须挂在外部发现合规门后。',
      );
      expect(
        reader,
        contains(
          'finalboolonline=isOnlineSourcesDomainAvailable('
          'OnlineSourcesDomain.novel,);',
        ),
        reason: '书架来源 / 扩展必须问小说在线源的合规 + 平台门。',
      );
      for (final String kind in <String>['onlineSources', 'extensions']) {
        expect(
          reader,
          contains(
            'if(online)MediaLibraryViewSpec(kind:MediaLibraryViewKind.$kind,',
          ),
          reason: '书架「$kind」视图必须挂在在线源门后。',
        );
      }

      final String manga = compactCode(
        read('lib/src/media/manga/manga_library_page.dart'),
      );
      expect(
        manga,
        contains(
          'if(StoreRestrictedCapability.externalDiscovery.isAvailable)'
          'MediaLibraryViewSpec(kind:MediaLibraryViewKind.discover,',
        ),
        reason: '漫画「发现」（AniList 榜单 / 来源热门 / mokuro.moe）必须挂在合规门后。',
      );
      for (final String kind in <String>['onlineSources', 'extensions']) {
        expect(
          manga,
          contains(
            'if(isOnlineSourcesDomainAvailable(OnlineSourcesDomain.manga))'
            'MediaLibraryViewSpec(kind:MediaLibraryViewKind.$kind,',
          ),
          reason: '漫画「$kind」视图必须挂在在线漫画源合规门后。',
        );
      }

      final String video = compactCode(
        read('lib/src/pages/implementations/video_library_shell.dart'),
      );
      expect(
        video,
        contains(
          'if(StoreRestrictedCapability.externalDiscovery.isAvailable)'
          'LibrarySectionTab<VideoLibrarySection>('
          'value:VideoLibrarySection.discover,',
        ),
        reason: '视频「发现」（番剧发现 → 资源索引器 → 种子获取）必须挂在合规门后。',
      );
      expect(
        video,
        contains(
          'finalboolonline=isOnlineSourcesDomainAvailable('
          'OnlineSourcesDomain.video,);',
        ),
      );
      for (final String section in <String>['onlineSources', 'extensions']) {
        expect(
          video,
          contains(
            'if(online)LibrarySectionTab<VideoLibrarySection>('
            'value:VideoLibrarySection.$section,',
          ),
          reason: '视频「$section」分区必须挂在视频源合规门后。',
        );
      }

      // 游戏「发现」与其它库页同样自己过门，不靠「iOS 没有游戏模块」这条会变的前提。
      final String game = compactCode(
        read('lib/src/pages/implementations/game_shared.dart'),
      );
      expect(
        game,
        contains(
          'if(StoreRestrictedCapability.externalDiscovery.isAvailable)'
          'GameSection.discover,',
        ),
        reason: '游戏「发现」子区必须挂在外部发现合规门后。',
      );

      // 上面只证明「有一处带门的写法」；再钉死同一文件里没有第二处不带门的入口：
      // 每类入口的全部出现次数必须等于带门的出现次数。
      void expectAllGated(String source, String entry, String gate) {
        final int total = entry.allMatches(source).length;
        expect(total, greaterThan(0), reason: '找不到入口 $entry');
        expect(
          '$gate$entry'.allMatches(source).length,
          total,
          reason: '$entry 有不带合规门的出现',
        );
      }

      const String discoverGate =
          'if(StoreRestrictedCapability.externalDiscovery.isAvailable)';
      expectAllGated(game, 'GameSection.discover,', discoverGate);
      for (final String source in <String>[reader, manga]) {
        expectAllGated(
          source,
          'MediaLibraryViewSpec(kind:MediaLibraryViewKind.discover,',
          discoverGate,
        );
      }
      expectAllGated(
        video,
        'LibrarySectionTab<VideoLibrarySection>('
        'value:VideoLibrarySection.discover,',
        discoverGate,
      );
      for (final String kind in <String>['onlineSources', 'extensions']) {
        expectAllGated(
          reader,
          'MediaLibraryViewSpec(kind:MediaLibraryViewKind.$kind,',
          'if(online)',
        );
        expectAllGated(
          manga,
          'MediaLibraryViewSpec(kind:MediaLibraryViewKind.$kind,',
          'if(isOnlineSourcesDomainAvailable(OnlineSourcesDomain.manga))',
        );
        expectAllGated(
          video,
          'LibrarySectionTab<VideoLibrarySection>('
              'value:VideoLibrarySection.$kind,',
          'if(online)',
        );
      }

      // 浏览模块的可用性委托给合规边界的唯一真相源，不自己写平台判断。
      expect(
        compactCode(read('lib/src/models/module_id.dart')),
        contains(
          'ModuleId.browse=>StoreRestrictedCapability.downloads.availableOn('
          'isIOS:isIOS,),',
        ),
      );
      final String browse = compactCode(
        read('lib/src/pages/implementations/browse_page.dart'),
      );
      expect(
        browse,
        contains('BrowseTab.discover=>_buildResourceHub(),'),
        reason: '发现页签就是资源发现 hub，只在浏览模块里构建。',
      );
      expect(
        browse,
        contains(
          'finalbooldiscover='
          'StoreRestrictedCapability.externalDiscovery.isAvailable&&',
        ),
        reason: '发现页签自己问 externalDiscovery，不只靠模块委托的 downloads 能力。',
      );
      expect(
        browse,
        isNot(contains('Platform.isIOS')),
        reason: '消费端不得各自写平台判断，只问 StoreRestrictedCapability。',
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
      // 发现服务 2026-09-30 起下沉到引擎（无头服务端也用），门变成 production 的
      // 必填参数：引擎里没有 app 的合规判据，每个 app 装配点必须显式把
      // externalDiscovery 传进去——漏传编译不过，传错由下面逐个装配点钉死。
      final String source = compactCode(
        read(
          '../packages/fushi_engine/lib/media/video/discovery/'
          'video_discovery_service.dart',
        ),
      );
      expect(source, contains('requiredbooldiscoveryAvailable,'));
      for (final String caller in <String>[
        'lib/src/pages/implementations/home_page.dart',
        'lib/src/media/video/acquisition/app_video_acquisition_assembly.dart',
      ]) {
        final String wiring = compactCode(read(caller));
        final int calls = 'VideoDiscoveryService.production('
            .allMatches(wiring)
            .length;
        final int gated =
            'discoveryAvailable:'
                    'StoreRestrictedCapability.externalDiscovery.isAvailable,'
                .allMatches(wiring)
                .length;
        expect(calls, greaterThan(0), reason: caller);
        expect(gated, calls, reason: '$caller 的每个发现服务装配点都要过门');
      }
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

      // 首页入口：偏好就绪 + 两道门（AI 未指派 / runtime 没起改在点击时引导，
      // 不再藏入口——藏了新用户就永远找不到它）。
      expect(
        compactCode(read('lib/src/pages/implementations/home_page.dart')),
        contains(
          'boolget_canAiAcquire=>appModelNoUpdate.isPreferencesReady&&'
          '$gates;',
        ),
      );

      // 设置分类：section 级 visible，正文 / 主从详情 / 搜索索引三条路径共用。
      expect(
        compactCode(read('lib/src/settings/settings_schema_ai.dart')),
        contains(
          "id:'ai.video_download',title:t.ai_video_download_section,"
          'visible:(SettingsContextc)=>$gates&&'
          'c.appModel.moduleVisibility.isEnabled(ModuleId.browse),',
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
          'feature!=AiFeature.acquire||($gates);',
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

    test('漫画在线源三节（浏览模块）由 onlineMangaSource 门控', () {
      // 2026-09-27 起漫画在线源从「来源」导入视图拆进 MangaOnlineSourcesView，
      // 只由「浏览」模块挂载；导入视图只剩本地来源。
      final String importPage = compactCode(
        read('lib/src/media/manga/manga_sources_page.dart'),
      );
      expect(importPage, isNot(contains('MihonExtensionsPage')));
      expect(importPage, isNot(contains('MihonInstalledSourcesSection')));
      final String source = compactCode(
        read('lib/src/media/manga/manga_online_sources_view.dart'),
      );
      expect(
        source,
        contains(
          'finalboolonlineSourcesAvailable='
          'StoreRestrictedCapability.onlineMangaSource.isAvailable;',
        ),
      );
      expect(source, contains('elseif(onlineSourcesAvailable)'));
      expect(
        source,
        contains('if(onlineSourcesAvailable&&manager!=null)'),
        reason: 'Mihon 扩展提供的源行也在这节里，不能只挡住标题。',
      );
      expect(
        compactCode(
          read('lib/src/pages/implementations/browse_online_sources_view.dart'),
        ),
        contains(
          'OnlineSourcesDomain.manga=>'
          'StoreRestrictedCapability.onlineMangaSource.isAvailable,',
        ),
        // 漫画域只问合规门、不再叠 Mihon 宿主门：内置 mokuro.moe 不需要扩展宿主，
        // Linux 上它的开关要有入口（PR #1707 审查）；没有宿主时扩展相关的节由
        // MangaOnlineSourcesView 自己换成「不可用」说明（上面几条断言钉的就是它）。
        reason: '浏览页签是否出现漫画域也问同一道合规门。',
      );
    });

    test('视频在线源三段（Aniyomi，浏览模块）由 onlineVideoSource 门控', () {
      // 判据只写在 video_online_sources_gate.dart 一处（合规门 + 运行时平台门），
      // 浏览页只问它——这条边界失效是静默的（本地与 CI 全绿、上架才被拒）。
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
      expect(
        compactCode(
          read('lib/src/pages/implementations/media_sources_page.dart'),
        ),
        isNot(contains('animeMihonManager')),
        reason: '视频导入页只剩本地来源，不得再取 animeMihonManager。',
      );
      final String sources = compactCode(
        read('lib/src/pages/implementations/browse_online_sources_view.dart'),
      );
      expect(
        sources,
        contains(
          'MihonManager?get_animeManager=>'
          'isVideoOnlineSourcesAvailable?_appModel.animeMihonManager:null;',
        ),
        reason: '浏览页取 animeMihonManager（仓库 / 扩展 / 在线源）必须挂在这个门后。',
      );
      expect(
        sources,
        contains('OnlineSourcesDomain.video=>isVideoOnlineSourcesAvailable,'),
        reason: '浏览页签是否出现视频域也问同一道门。',
      );
      expect(
        sources,
        contains('finalMihonManagermanager=>_videoSlivers(manager),'),
        reason: '三段的 sliver 只在拿到 manager 时才进树，门失效时整段不出现。',
      );
      expect(
        sources,
        isNot(contains('Platform.isIOS')),
        reason: '消费端不得各自写平台判断，只问 StoreRestrictedCapability。',
      );
    });

    test('播放页从媒体库重开在线源集时，取 animeMihonManager 挂在同一道门后', () {
      // 媒体库里的在线源行（anime-source://）会经备份 / 同步出现在任何平台上；播放页
      // 重开它时若在门外取 animeMihonManager，iOS 上就会起在线源宿主（Linux 上直接
      // 抛 UnsupportedError）。门不过时抛 AnimeSourceLaunchUnavailable，走原有的
      // 「扩展不可用」失败提示。
      final String page = compactCode(
        read('lib/src/pages/implementations/video_fushi_page.dart'),
      );
      const String gate =
          'if(!isVideoOnlineSourcesAvailable){'
          'throwconstAnimeSourceLaunchUnavailable(';
      const String use = 'manager:appModel.animeMihonManager,';
      expect(page, contains(gate));
      expect(page, contains(use));
      expect(
        'animeMihonManager'.allMatches(page).length,
        1,
        reason: '播放页只许这一处取 animeMihonManager，且它在门后。',
      );
      final int gateAt = page.indexOf(gate);
      final int useAt = page.indexOf(use);
      expect(gateAt, lessThan(useAt), reason: '门必须先于取用。');
      expect(
        page.substring(gateAt, useAt),
        allOf(
          contains('launch=awaitbuildAnimeSourceLaunch('),
          isNot(contains('}catch(')),
        ),
        reason: '门与取用在同一个 try 里紧挨着：门不过就不会走到取用。',
      );
      final List<File> parts =
          Directory('lib/src/pages/implementations/video_fushi')
              .listSync()
              .whereType<File>()
              .where((File f) => f.path.endsWith('.dart'))
              .toList();
      expect(parts, isNotEmpty);
      for (final File part in parts) {
        expect(
          compactCode(part.readAsStringSync()),
          isNot(contains('animeMihonManager')),
          reason: '${part.path}：播放页的 part 不得绕开门取 animeMihonManager。',
        );
      }
    });

    test('小说源三段（LNReader，浏览模块）由 onlineNovelSource 门控', () {
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
      expect(
        compactCode(
          read('lib/src/pages/implementations/media_sources_page.dart'),
        ),
        isNot(contains('lnReaderManager')),
        reason: '书导入页只剩本地来源，不得再取 lnReaderManager。',
      );
      final String sources = compactCode(
        read('lib/src/pages/implementations/browse_online_sources_view.dart'),
      );
      expect(
        sources,
        contains(
          'LnReaderManager?get_novelManager=>'
          'isNovelOnlineSourcesAvailable?_appModel.lnReaderManager:null;',
        ),
        reason: '浏览页取 lnReaderManager（仓库 / 扩展 / 在线源）必须挂在这个门后。',
      );
      expect(
        sources,
        contains('OnlineSourcesDomain.novel=>isNovelOnlineSourcesAvailable,'),
      );
      expect(
        sources,
        contains('finalLnReaderManagermanager=>_novelSlivers(manager),'),
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

  group('Aidoku 已从本仓整体移除', () {
    test('Dart 功能层（运行时 / 仓库 / 安装包 / 源浏览）不再存在', () {
      expect(
        Directory('lib/src/media/manga/aidoku').existsSync(),
        isFalse,
        reason:
            'Aidoku 的 Dart 功能层已整体删除；目录回来就意味着有人在把「运行时加载 '
            '第三方 WASM 源」这条能力接回来，必须先过 onlineMangaSource 合规门。',
      );
      final List<String> offenders = <String>[
        for (final FileSystemEntity entity
            in Directory('lib').listSync(recursive: true))
          if (entity is File &&
              entity.path.endsWith('.dart') &&
              entity
                  .readAsStringSync()
                  .contains('package:fushi/src/media/manga/aidoku/'))
            entity.path,
      ];
      expect(offenders, isEmpty);
      expect(
        Directory('../native/aidoku_runtime').existsSync(),
        isFalse,
        reason: 'Rust 宿主源码随 iOS / macOS 宿主一并移除。',
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

    // 曾断言「workflow 里不出现 aarch64-apple-ios / apple-darwin」：当时 Apple 的 Rust
    // target 只为 Aidoku runtime 而装，字符串缺席就等于「不构建 Aidoku」。互联 P2P
    // 隧道（native/fushi_p2p，docs/specs/2026-09-28-interconnect-remote-reach.md）
    // 起 iOS 静态库 / macOS dylib 也要这些 target，那个近似判据不再成立。改钉真正
    // 要守的事实：装 Apple Rust target 的 job 只能是在构建 fushi_p2p，且全程不碰 Aidoku。
    test('CI 的 Apple Rust target 只服务 fushi_p2p，不构建 Aidoku runtime', () {
      for (final String path in <String>[
        '../.github/workflows/build-multiplatform.yml',
        '../.github/workflows/release-desktop.yml',
      ]) {
        final String workflow = read(path);
        expect(workflow.toLowerCase(), isNot(contains('aidoku')), reason: path);
        final Map<String, String> jobs = workflowJobs(workflow);
        expect(jobs, isNotEmpty, reason: '切不出 job 时下面的核对就是空转');
        for (final MapEntry<String, String> job in jobs.entries) {
          if (!job.value.contains('apple-ios') &&
              !job.value.contains('apple-darwin')) {
            continue;
          }
          expect(
            job.value,
            contains('native/fushi_p2p'),
            reason:
                '$path 的 job ${job.key} 装了 Apple Rust target，却不是在构建 '
                'fushi_p2p——Apple 上唯一允许的 Rust 构建就是它。',
          );
        }
      }
    });

    test('macOS 侧的 Aidoku 宿主也已整条移除', () {
      // 曾是反向断言「不要顺手把 macOS 也删了」；macOS 宿主随后按同一口径移除，
      // 这里改钉新事实：两条 macOS workflow 不再打 runtime 进 bundle，发布包里
      // 不带 WASM 解释器。
      for (final String path in <String>[
        '../.github/workflows/build-multiplatform.yml',
        '../.github/workflows/release-desktop.yml',
      ]) {
        final String workflow = read(path);
        expect(workflow, isNot(contains('tool/aidoku/')));
        expect(workflow, isNot(contains('aidoku_runtime')));
        // 这里曾禁 `apple-darwin`：当时 macOS Rust target 只为 Aidoku runtime 而装。
        // 现在 native/fushi_anki_sync（Anki 同步 helper）正当地需要 universal macOS
        // 构建，按 target 三元组禁会误伤它；改成直接禁任何 Aidoku 提及，边界不变。
        expect(
          workflow.toLowerCase(),
          isNot(contains('aidoku')),
          reason: '$path 又出现了 Aidoku 相关构建步骤；macOS / iOS 的 Aidoku 宿主已整条移除。',
        );
      }
      expect(Directory('../tool/aidoku').existsSync(), isFalse);
      expect(
        File('../native/aidoku_runtime/src/main.rs').existsSync(),
        isFalse,
      );
    });
  });

  group('蓝光 AACS 解密由 aacsDecryption 门控', () {
    test('app 用合规判据给引擎装配点赋值，引擎默认值按同一判据 fail-closed', () {
      expect(
        compactCode(read('lib/src/engine_bindings.dart')),
        contains(
          'aacsDecryptionAvailable='
          'StoreRestrictedCapability.aacsDecryption.isAvailable;',
        ),
      );
      final String session = compactCode(
        read(
          '../packages/fushi_engine/lib/media/video/bluray/'
          'aacs_media_session.dart',
        ),
      );
      expect(
        session,
        contains('boolaacsDecryptionAvailable=!Platform.isIOS;'),
        reason:
            '全局变量带不过 isolate 边界：后台 isolate 里没人赋值时，'
            'iOS 也必须默认不解密、不下载 KEYDB。',
      );
      expect(
        session,
        contains(
          'if(!aacsDecryptionAvailable)'
          'throwBlurayEncryptedStreamException(path);',
        ),
        reason: '门要挡在读取 / 下载播放配置之前。',
      );
      final int gate = session.indexOf('if(!aacsDecryptionAvailable)');
      final int load = session.indexOf('loadAacsConfiguration(');
      expect(gate, greaterThanOrEqualTo(0));
      expect(load, greaterThan(gate));
    });
  });
}

/// 把 GitHub Actions workflow 按顶层 job 切开（job 名 → 该 job 的全文）。只认
/// `jobs:` 下两格缩进的 `<name>:` 行作 job 起点，足够本守卫按 job 归属判断。
Map<String, String> workflowJobs(String workflow) {
  final Map<String, String> jobs = <String, String>{};
  final RegExp jobHeader = RegExp(r'^  ([A-Za-z0-9_-]+):\s*$');
  bool inJobs = false;
  String? current;
  final StringBuffer buffer = StringBuffer();
  void flush() {
    if (current != null) jobs[current] = buffer.toString();
    buffer.clear();
  }

  for (final String line in workflow.split('\n')) {
    if (line.startsWith('jobs:')) {
      inJobs = true;
      continue;
    }
    if (!inJobs) continue;
    final RegExpMatch? m = jobHeader.firstMatch(line.trimRight());
    if (m != null) {
      flush();
      current = m.group(1);
      continue;
    }
    buffer.writeln(line);
  }
  flush();
  return jobs;
}
