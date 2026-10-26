import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 一个「UI 动作门面」：页面按钮背后的操作集中在 [className] 上，页面与桌面控制通道
/// 都只调它。
class _Facade {
  const _Facade({
    required this.file,
    required this.className,
    required this.ctlFiles,
    required this.uiFiles,
    required this.uiForbidden,
    required this.sampleMethod,
    this.exempt = const <String, String>{},
  });

  /// 门面类所在文件（相对 `fushi/`）。
  final String file;
  final String className;

  /// 必须引用门面每个公开方法的控制通道路由文件。
  final List<String> ctlFiles;

  /// 只许经门面动手的页面文件。
  final List<String> uiFiles;

  /// 页面里不许再出现的「绕过门面」调用（直接写库 / 直接驱动服务）。
  final List<String> uiForbidden;

  /// 扫描器自检用：门面上一定有的一个公开方法名（读不到它说明扫描正则坏了）。
  final String sampleMethod;

  /// 有意不进控制通道的公开方法 → 理由。
  final Map<String, String> exempt;
}

/// 已登记的门面。某个页面的操作抽成门面后在这里加一行，CLI 漏接的操作就会被抓到。
const List<_Facade> _facades = <_Facade>[
  _Facade(
    file: 'lib/src/sync/app_download_host.dart',
    className: 'AppSubscriptionHost',
    ctlFiles: <String>['lib/src/ops/ctl_download_subscription_routes.dart'],
    uiFiles: <String>[
      'lib/src/pages/implementations/video_download_subscriptions_panel.dart',
    ],
    uiForbidden: <String>[
      'updateVideoDownloadSubscription',
      'deleteVideoDownloadSubscription(',
      'videoDownloadSubscriptionService',
      'releaseSubscriptionSeedsOutsideTarget',
    ],
    sampleMethod: 'checkNow',
    exempt: <String, String>{'create': '新建订阅走 aidl（AI 下视频）/ 发现页，它们各自已有 CLI 入口'},
  ),
  // 视频导入对话框「粘贴 URL 导入」：门面与对话框在同一个文件（共用文件私有的封面
  // 临界区助手 _runVideoImportCoverMutation 等，且 video_import_cover_gate_guard_test
  // 按这个文件切片钉锁顺序），所以不登记 uiFiles——整文件扫禁用词会扫到门面自己。
  // 对话框只经门面落库由 video_import_cover_gate_guard_test 钉住。
  _Facade(
    file: 'lib/src/media/video/video_import_dialog.dart',
    className: 'StreamVideoUrlImporter',
    ctlFiles: <String>['lib/src/ops/ctl_url_import_routes.dart'],
    uiFiles: <String>[],
    uiForbidden: <String>[],
    sampleMethod: 'importUrl',
  ),
  _Facade(
    file: 'lib/src/media/metadata/book_metadata_scrape_facade.dart',
    className: 'BookMetadataScrapeFacade',
    ctlFiles: <String>['lib/src/ops/ctl_book_metadata_routes.dart'],
    uiFiles: <String>[
      'lib/src/media/metadata/book_cover_scrape_dialog.dart',
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
    ],
    uiForbidden: <String>[
      'downloadImageToTempFile',
      'fetchDlsiteById(',
      'searchDlsite(',
      'parseBangumiSubjectUrl',
      'applyBookCoverOverride',
    ],
    sampleMethod: 'applyToBook',
    exempt: <String, String>{
      'currentState':
          '只给 AI 撤销判「之后被手动改过」用（op_descriptions_book_metadata），不是 UI 动作',
      'restore': '只给 AI 撤销写回快照用（op_descriptions_book_metadata），不是 UI 动作',
    },
  ),
];

/// [source] 里 `class [name]` 的类体（按花括号配平）。
String _classBody(String source, String name) {
  final int start = source.indexOf(RegExp('class $name\\b'));
  if (start < 0) throw StateError('找不到 class $name');
  final int open = source.indexOf('{', start);
  int depth = 0;
  for (int i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) {
      return source.substring(open, i + 1);
    }
  }
  throw StateError('class $name 花括号不配平');
}

/// 去掉 `//` / `///` 注释：注释里提到方法名既不算调用，也不算绕过。
String _code(String path) => File(
  path,
).readAsStringSync().replaceAll(RegExp(r'(^|\s)//.*$', multiLine: true), '');

/// 类体里的公开实例方法名（两格缩进的成员声明，返回 Future / void / 具体类型）。
List<String> _publicMethods(String body) => <String>[
  for (final RegExpMatch m in RegExp(
    r'^  (?!static )(?:[A-Z]\w*(?:<.*>)?\??|void)\s+([a-z]\w*)\(',
    multiLine: true,
  ).allMatches(body))
    m.group(1)!,
];

/// 订阅这类页面的操作若写在 State 私有方法里，控制通道就没法调「同一个方法」，CLI
/// 只能漏接或另写一份（两份实现迟早语义分叉——重新启用 oneShot 订阅时漏清
/// `fulfilledAt` 就是这么来的）。这里钉两件事：
/// 1. 页面只经门面动手，不直接写库 / 驱动服务；
/// 2. 门面上每个公开方法都被控制通道路由用到（`ctl_cli_route_coverage_guard_test`
///    再保证每条路由都有 CLI 命令），即「UI 能做的，CLI 都能做」。
void main() {
  for (final _Facade facade in _facades) {
    group(facade.className, () {
      final String body = _classBody(_code(facade.file), facade.className);
      final List<String> methods = _publicMethods(body);

      test('扫描器能读到门面方法', () {
        expect(methods, isNotEmpty);
        expect(methods, contains(facade.sampleMethod));
      });

      test('每个公开方法都被控制通道路由用到', () {
        final String ctl = <String>[
          for (final String f in facade.ctlFiles) _code(f),
        ].join('\n');
        final List<String> missing = <String>[
          for (final String m in methods)
            if (!facade.exempt.containsKey(m) && !ctl.contains('.$m(')) m,
        ];
        expect(
          missing,
          isEmpty,
          reason:
              '${facade.className} 的这些操作没有控制通道路由（CLI 做不到）：'
              '${missing.join(', ')}',
        );
      });

      test('豁免条目都还是门面方法', () {
        for (final String m in facade.exempt.keys) {
          expect(methods, contains(m), reason: '豁免条目已无对应方法：$m');
        }
      });

      for (final String ui in facade.uiFiles) {
        test('$ui 只经门面动手', () {
          final String source = _code(ui);
          expect(source, contains(facade.className));
          final List<String> bypass = <String>[
            for (final String needle in facade.uiForbidden)
              if (source.contains(needle)) needle,
          ];
          expect(
            bypass,
            isEmpty,
            reason: '页面绕过 ${facade.className} 直接动手：${bypass.join(', ')}',
          );
        });
      }
    });
  }
}
