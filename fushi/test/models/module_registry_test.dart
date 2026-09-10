// 「功能模块」值域与映射表的契约测试。
//
// 这些映射是模块门控的**唯一真值**：漏一条映射 = 某个入口永远关不掉（或者更糟，
// 某个恒在的面被误关）。穷尽 switch 已经让「加模块时漏写映射」编译不过；这里钉的
// 是编译器管不到的另一半——映射**内容**是否正确，以及那几条刻意判 null 的例外是不
// 是还在（它们每一条背后都有一个具体的产品决定，被人「顺手补全」就会静默回归）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/pages/implementations/home_page.dart' show HomeTab;
import 'package:fushi/src/settings/settings_destination.dart'
    show SettingsDestinationId;
import 'package:fushi/src/shortcuts/shortcut_action.dart' show ShortcutScope;
import 'package:fushi_core/fushi_core.dart' show MediaKind;

void main() {
  group('ModuleId', () {
    test('持久化键唯一且不带 .name 巧合依赖', () {
      final Set<String> keys = ModuleId.allPrefKeys;
      expect(
        keys.length,
        ModuleId.values.length,
        reason: '两个模块共用一个 pref key 会让它们的开关互相覆盖',
      );
      for (final ModuleId id in ModuleId.values) {
        expect(
          id.prefKey,
          startsWith('module_'),
          reason: 'pref 键命名前缀是备份/Profile 排除名单与诊断日志的识别依据',
        );
      }
    });

    test('存量七个模块的持久化键逐字冻结（Never break userspace）', () {
      // 用户已经关掉的模块必须在升级后仍然是关的。这七个键改一个字，线上用户的
      // 设置就会静默回落成「全开」。lookup 的键是历史名 module_dictionaries_enabled，
      // 与枚举名不一致是**有意**的，别为了好看去改。
      expect(ModuleId.books.prefKey, 'module_books_enabled');
      expect(ModuleId.manga.prefKey, 'module_manga_enabled');
      expect(ModuleId.video.prefKey, 'module_video_enabled');
      expect(ModuleId.games.prefKey, 'module_games_enabled');
      expect(ModuleId.downloads.prefKey, 'module_downloads_enabled');
      expect(ModuleId.lookup.prefKey, 'module_dictionaries_enabled');
      expect(
        ModuleId.browserExtension.prefKey,
        'module_browser_extension_enabled',
      );
    });

    test('平台判据只有 games / browserExtension / downloads 三条', () {
      for (final ModuleId id in ModuleId.values) {
        final bool onWindowsDesktop = id.availableOn(
          isWindows: true,
          isDesktop: true,
          isIOS: false,
        );
        // 判 Android 而不是笼统的「移动端」：downloads 的判据是 iOS 本身
        // （App Store 合规），两个移动平台在这条上结论相反。
        final bool onAndroid = id.availableOn(
          isWindows: false,
          isDesktop: false,
          isIOS: false,
        );
        expect(onWindowsDesktop, isTrue, reason: 'Windows 桌面上全部模块都可用');
        if (id == ModuleId.games || id == ModuleId.browserExtension) {
          expect(onAndroid, isFalse, reason: '$id 是桌面/Windows 限定');
        } else {
          expect(onAndroid, isTrue, reason: '$id 不该有平台限制');
        }
      }
      // galgame hook 只做 Windows：非 Windows 桌面（macOS/Linux）也不能有。
      expect(
        ModuleId.games.availableOn(
          isWindows: false,
          isDesktop: true,
          isIOS: false,
        ),
        isFalse,
      );
      // 浏览器扩展是「电脑才有」，非 Windows 桌面照样有。
      expect(
        ModuleId.browserExtension.availableOn(
          isWindows: false,
          isDesktop: true,
          isIOS: false,
        ),
        isTrue,
      );
      // 下载中心：唯一一条不是「这个平台做不做得到」的判据。完整边界与它的
      // 兄弟能力（发现源 / 在线漫画源）见 test/build/ios_store_compliance_guard_test.dart。
      expect(
        ModuleId.downloads.availableOn(
          isWindows: false,
          isDesktop: false,
          isIOS: true,
        ),
        isFalse,
      );
    });
  });

  group('ModuleVisibility', () {
    test('resolve 把平台不可用的模块直接剔除，与 pref 真值无关', () {
      final ModuleVisibility mobile = ModuleVisibility.resolve(
        prefOf: (ModuleId _) => true,
        isWindows: false,
        isDesktop: false,
        isIOS: false,
      );
      expect(mobile.isEnabled(ModuleId.games), isFalse);
      expect(mobile.isEnabled(ModuleId.browserExtension), isFalse);
      expect(mobile.isEnabled(ModuleId.books), isTrue);
    });

    test('resolve 尊重 pref：平台可用但用户关掉的不出现', () {
      final ModuleVisibility only = ModuleVisibility.resolve(
        prefOf: (ModuleId id) => id == ModuleId.books,
        isWindows: true,
        isDesktop: true,
        isIOS: false,
      );
      expect(only.enabled, <ModuleId>{ModuleId.books});
    });

    test('isEnabledOrUngated：null 表示恒在', () {
      const ModuleVisibility none = ModuleVisibility(<ModuleId>{});
      expect(none.isEnabledOrUngated(null), isTrue);
      expect(none.isEnabledOrUngated(ModuleId.video), isFalse);
    });
  });

  group('HomeTab 映射', () {
    test('首页与设置恒在——它们是全部模块关光后的安全回退面', () {
      expect(moduleOfHomeTab(HomeTab.home), isNull);
      expect(moduleOfHomeTab(HomeTab.settings), isNull);
      const ModuleVisibility none = ModuleVisibility(<ModuleId>{});
      expect(isHomeTabVisible(HomeTab.home, none), isTrue);
      expect(isHomeTabVisible(HomeTab.settings, none), isTrue);
    });

    test('homeTabOfModule 与 moduleOfHomeTab 互为逆映射', () {
      for (final ModuleId id in ModuleId.values) {
        final HomeTab? tab = homeTabOfModule(id);
        if (tab == null) continue;
        expect(
          moduleOfHomeTab(tab),
          id,
          reason: '$id → $tab → ${moduleOfHomeTab(tab)} 不闭合，两张表已漂移',
        );
      }
      for (final HomeTab tab in HomeTab.values) {
        final ModuleId? id = moduleOfHomeTab(tab);
        if (id == null) continue;
        expect(homeTabOfModule(id), tab);
      }
    });

    test('四个横切模块没有 tab（只有设置分类与散落入口）', () {
      expect(homeTabOfModule(ModuleId.listening), isNull);
      expect(homeTabOfModule(ModuleId.cardCreation), isNull);
      expect(homeTabOfModule(ModuleId.services), isNull);
      expect(homeTabOfModule(ModuleId.sync), isNull);
    });
  });

  group('SettingsDestinationId 映射', () {
    test('全部模块关光时，恒在分类仍然可见', () {
      const ModuleVisibility none = ModuleVisibility(<ModuleId>{});
      // 每一条都是一个具体的产品决定，不是「还没写」：
      // appearance/system/storage/profiles 是设备级；reading 是 books 与 manga
      // 共用（漫画库页内嵌的就是它）；lookup 是「关页面入口但留查词能力」的例外。
      for (final SettingsDestinationId id in <SettingsDestinationId>[
        SettingsDestinationId.appearance,
        SettingsDestinationId.profiles,
        SettingsDestinationId.reading,
        SettingsDestinationId.lookup,
        SettingsDestinationId.storage,
        SettingsDestinationId.system,
      ]) {
        expect(
          isSettingsDestinationVisible(id, none),
          isTrue,
          reason: '$id 必须恒在——它不属于任何模块',
        );
      }
    });

    test('四个 synthetic 分类不受模块门控（它们不是设置主页上的一级分类）', () {
      const ModuleVisibility none = ModuleVisibility(<ModuleId>{});
      for (final SettingsDestinationId id in <SettingsDestinationId>[
        SettingsDestinationId.readerQuickSettings,
        SettingsDestinationId.appIcon,
        SettingsDestinationId.videoQuickSettings,
        SettingsDestinationId.shortcuts,
      ]) {
        expect(
          moduleOfSettingsDestination(id),
          isNull,
          reason: '$id 是合成面板，按模块藏它只会让整个面板消失',
        );
        expect(isSettingsDestinationVisible(id, none), isTrue);
      }
    });

    test('成对分类挂同一个模块（关一半比不关更糟）', () {
      expect(
        moduleOfSettingsDestination(SettingsDestinationId.mediaTracking),
        moduleOfSettingsDestination(SettingsDestinationId.services),
        reason: '媒体追踪靠在线服务的凭据跑，分成两个开关只会让用户关了一半',
      );
      expect(
        moduleOfSettingsDestination(SettingsDestinationId.interconnect),
        moduleOfSettingsDestination(SettingsDestinationId.syncBackup),
        reason: '互联是从同步备份拆出去的分类，共享同一套后端',
      );
    });

    test('模块关掉后它的分类确实不可见', () {
      const ModuleVisibility none = ModuleVisibility(<ModuleId>{});
      for (final SettingsDestinationId id in SettingsDestinationId.values) {
        final ModuleId? owner = moduleOfSettingsDestination(id);
        if (owner == null) continue;
        expect(
          isSettingsDestinationVisible(id, none),
          isFalse,
          reason: '$id 属于 $owner，模块关掉后不该还列在设置主页/搜索索引里',
        );
      }
    });
  });

  group('ShortcutScope 映射', () {
    test('划词弹窗内部导航恒在——它属于查词能力，不是查词页面', () {
      // 用户拍板：关掉「查词」只关页面入口，阅读器/视频里的划词弹窗要照常能用，
      // 弹窗里的「上/下一个词条」自然也得留着。
      expect(moduleOfShortcutScope(ShortcutScope.dictionaryPopup), isNull);
    });

    test('app 外系统级取词热键跟着 lookup 关——关掉模块不该还能装系统钩子', () {
      expect(
        moduleOfShortcutScope(ShortcutScope.globalExternal),
        ModuleId.lookup,
      );
    });

    test('通用作用域恒在', () {
      for (final ShortcutScope scope in <ShortcutScope>[
        ShortcutScope.global,
        ShortcutScope.universal,
        ShortcutScope.home,
        ShortcutScope.gamepad,
      ]) {
        expect(moduleOfShortcutScope(scope), isNull, reason: '$scope 跨模块常驻');
      }
    });
  });

  group('MediaKind 映射', () {
    test('epub 与 srt 都归 books（字幕书也是书）', () {
      expect(moduleOfMediaKind(MediaKind.epub), ModuleId.books);
      expect(moduleOfMediaKind(MediaKind.srt), ModuleId.books);
    });

    test('visibleMediaKinds 随模块收缩', () {
      const ModuleVisibility booksOnly = ModuleVisibility(<ModuleId>{
        ModuleId.books,
      });
      expect(visibleMediaKinds(booksOnly), <MediaKind>{
        MediaKind.epub,
        MediaKind.srt,
      });
      const ModuleVisibility none = ModuleVisibility(<ModuleId>{});
      expect(visibleMediaKinds(none), isEmpty);
    });
  });
}
