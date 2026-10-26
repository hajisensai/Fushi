import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/widgets.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/custom_fonts_page.dart';
import 'package:fushi/src/pages/implementations/font_preview/system_font_catalog.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/reader/custom_font_library.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/settings/settings_cli_tasks.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

/// 字体库页（[CustomFontsPage]，外观 / 阅读 / 查词 / 游戏 / 听力五个入口是同一个
/// 库、只差新增字体默认挂的用途）在控制通道上的条目。
///
/// - `config items appearance.font_catalog.cli.fonts ls|add|set|rm`：列出 / 导入本机
///   文件或压缩包 / 下载 URL / 下载推荐字体 / 添加系统字体 / 改用途与排序 / 删除。
/// - `config get|set appearance.font_catalog.cli.target.<用途>`：某用途的字体链。
/// - `config run appearance.font_catalog.cli.recommended|system_fonts`：列出可加的字体。
///
/// 业务全部走 [CustomFontLibrary]（与页面同一份目录状态、下载服务与读写函数）。
const String kCtlFontsIdPrefix = 'appearance.font_catalog.cli.';

String _id(String name) => '$kCtlFontsIdPrefix$name';

/// 测试注入点：生产 = [CustomFontLibrary.forApp]。
@visibleForTesting
CustomFontLibrary Function(AppModel appModel) ctlFontLibraryFactory =
    CustomFontLibrary.forApp;

CustomFontLibrary _lib(SettingsContext c) => ctlFontLibraryFactory(c.appModel);

String get _targetNames =>
    FontTarget.values.map((FontTarget t) => t.name).join(' / ');

/// 一行的 CLI 记录（不含内部字段）。
Map<String, Object?> ctlFontRecord(CustomFontCatalogRow row) {
  final String? path = row.path;
  return <String, Object?>{
    'id': row.id,
    'name': row.name,
    'kind': path == null ? 'system' : 'file',
    if (path != null) 'path': path,
    if (path != null) 'fileMissing': !File(path).existsSync(),
    'targets': <String>[
      for (final FontTarget target in FontTarget.values)
        if (row.targetEnabled.containsKey(target)) target.name,
    ],
  };
}

List<Map<String, Object?>> _records(List<CustomFontCatalogRow> rows) =>
    <Map<String, Object?>>[
      for (final CustomFontCatalogRow row in rows) ctlFontRecord(row),
    ];

List<CtlBodyPage> buildCtlFontsBodyPages() => <CtlBodyPage>[
  CtlBodyPage(
    breadcrumb:
        '${t.settings_destination_appearance} › ${t.custom_fonts_catalog_title}',
    items: <SettingsItem>[
      SettingsCustomItem(
        id: _id('fonts'),
        builder: (SettingsContext _) => const SizedBox.shrink(),
        searchTitle: t.custom_fonts_catalog_title,
        cliList: SettingsCliList(
          list: (SettingsContext c) async => _records(await _lib(c).list()),
          add: _addFont,
          update: _updateFont,
          remove: (SettingsContext c, String id) async {
            final CustomFontRemoval removal = await _lib(c).remove(id);
            if (removal.fileError != null) {
              // 目录已更新，文件没删掉：交给控制通道报错，别装作删干净了。
              throw StateError('已移出字体库，但删除字体文件失败：${removal.fileError}');
            }
          },
          fields: <SettingsCliParam>[
            const SettingsCliParam(
              'path',
              help: '新增来源①：本机字体文件或压缩包（ttf/otf/ttc/woff/woff2/zip…）',
              required: false,
              path: true,
            ),
            const SettingsCliParam(
              'url',
              help: '新增来源②：字体文件 / 压缩包的 http(s) 下载地址；多个镜像用 | 分隔',
              required: false,
            ),
            SettingsCliParam(
              'recommended',
              help: '新增来源③：推荐字体名（config run ${_id('recommended')} 列出）',
              required: false,
            ),
            SettingsCliParam(
              'system',
              help: '新增来源④：系统字体族名（config run ${_id('system_fonts')} 列出）',
              required: false,
            ),
            const SettingsCliParam(
              'name',
              help: '新增时覆盖显示名（path / url 来源）',
              required: false,
            ),
            SettingsCliParam(
              'targets',
              help: '用途，逗号分隔：$_targetNames；新增省略 = body，修改时整体替换（空串 = 不用于任何用途）',
              required: false,
            ),
            const SettingsCliParam(
              'position',
              help: '修改：挪到目录第 N 位（0 起）。目录顺序 = 各用途的字体链 / 缺字回退顺序',
              required: false,
            ),
          ],
        ),
      ),
      for (final FontTarget target in FontTarget.values)
        SettingsCustomItem(
          id: _id('target.${target.name}'),
          builder: (SettingsContext _) => const SizedBox.shrink(),
          searchTitle: '${t.custom_fonts_catalog_title} · ${target.name}',
          visible: (SettingsContext _) =>
              isFontTargetAvailableOnPlatform(target),
          cliValue: SettingsCliValue(
            read: (SettingsContext c) => _targetChainOf(target),
            write: (SettingsContext c, String raw) async {
              final List<String> keys = <String>[
                for (final String part in raw.split(','))
                  if (part.trim().isNotEmpty) part.trim(),
              ];
              await _lib(c).setTargetFonts(target, keys);
            },
            help:
                '该用途使用的字体显示名（或 id），逗号分隔；顺序跟随目录顺序（用 items set --position 调）；空串 = 清空',
          ),
        ),
      SettingsActionItem(
        id: _id('download'),
        title: t.custom_fonts_downloading,
        subtitle:
            '后台下载字体（URL 或推荐字体）；立即返回任务，fushi_cli task get <id> --wait 看进度，task cancel <id> 取消',
        cli: SettingsCliAction(
          run: _downloadFont,
          params: <SettingsCliParam>[
            const SettingsCliParam(
              'url',
              help: '字体文件 / 压缩包的 http(s) 地址；多个镜像用 | 分隔（与 recommended 二选一）',
              required: false,
            ),
            SettingsCliParam(
              'recommended',
              help: '推荐字体名（config run ${_id('recommended')} 列出）',
              required: false,
            ),
            const SettingsCliParam(
              'name',
              help: '覆盖显示名（url 来源）',
              required: false,
            ),
            SettingsCliParam(
              'targets',
              help: '用途，逗号分隔：$_targetNames；省略 = body',
              required: false,
            ),
          ],
        ),
        // 逃生口条目不进设置页渲染；页面的下载按钮自带进度条与取消。
        onTap: (SettingsContext _) =>
            throw UnsupportedError('${_id('download')} 只经控制通道执行'),
      ),
      SettingsActionItem(
        id: _id('recommended'),
        title: t.custom_fonts_recommended,
        subtitle: '列出推荐字体表（name 可作 items add --arg recommended=…）',
        cli: SettingsCliAction(run: _listRecommended),
        onTap: (SettingsContext c) =>
            _listRecommended(c, const <String, String>{}),
      ),
      SettingsActionItem(
        id: _id('system_fonts'),
        title: t.custom_fonts_add_system,
        subtitle: '列出本机系统字体族（family 可作 items add --arg system=…）',
        cli: SettingsCliAction(
          run: _listSystemFonts,
          params: const <SettingsCliParam>[
            SettingsCliParam('query', help: '按族名子串过滤（不分大小写）', required: false),
          ],
        ),
        onTap: (SettingsContext c) =>
            _listSystemFonts(c, const <String, String>{}),
      ),
    ],
  ),
];

/// 某用途当前的字体链（显示名，逗号分隔，目录顺序）。读的是 app 启动时装好、
/// 每次写穿后刷新的 [ReaderFushiSource.readerSettings]——阅读器 / 弹窗 / 浮窗
/// 渲染读的也是这一份。
String _targetChainOf(FontTarget target) {
  final ReaderSettings? settings = ReaderFushiSource.readerSettings;
  if (settings == null) throw StateError('阅读器设置尚未加载');
  return <String>[
    for (final Map<String, dynamic> entry in settings.fontsForTarget(target))
      if (entry['enabled'] != false) '${entry['name'] ?? ''}',
  ].join(',');
}

Set<FontTarget> _targetsArg(Map<String, String> fields, {required bool add}) {
  final String? raw = fields['targets'];
  if (raw == null) return add ? <FontTarget>{FontTarget.body} : <FontTarget>{};
  return parseFontTargets(raw);
}

Future<Object?> _addFont(SettingsContext c, Map<String, String> fields) async {
  final List<String> sources = <String>[
    for (final String key in <String>['path', 'url', 'recommended', 'system'])
      if ((fields[key] ?? '').trim().isNotEmpty) key,
  ];
  if (sources.length != 1) {
    throw ArgumentError('path / url / recommended / system 恰好给一个（收到 $sources）');
  }
  final Set<FontTarget> targets = _targetsArg(fields, add: true);
  final String? name = (fields['name'] ?? '').trim().isEmpty
      ? null
      : fields['name']!.trim();
  final CustomFontLibrary lib = _lib(c);
  // 网络下载走后台任务：立即返回任务号，`fushi_cli task get <id> --wait` 看进度 /
  // 结局，`task cancel <id>` 取消。本机文件 / 系统字体是秒级落地，同步完成。
  if (sources.single == 'url' || sources.single == 'recommended') {
    return <String, Object?>{
      'task': startCtlFontDownloadTask(
        lib,
        urls: sources.single == 'url' ? _urlsArg(fields['url']!) : null,
        recommended: sources.single == 'recommended'
            ? fields['recommended']!.trim()
            : null,
        targets: targets,
        overrideName: name,
      ).toJson(),
    };
  }
  final List<CustomFontCatalogRow> added;
  try {
    added = switch (sources.single) {
      'path' => await lib.importFile(
        fields['path']!,
        targets: targets,
        overrideName: name,
      ),
      _ => await lib.addSystemFamily(fields['system']!, targets: targets),
    };
  } on CustomFontLibraryException catch (e) {
    // 下载 / 解包失败不是参数错：映射成「稍后重试」类的状态错误。
    throw StateError(e.message);
  }
  return added.length == 1
      ? ctlFontRecord(added.single)
      : <String, Object?>{'id': added.first.id, 'added': _records(added)};
}

List<String> _urlsArg(String raw) => <String>[
  for (final String u in raw.split('|'))
    if (u.trim().isNotEmpty) u.trim(),
];

/// 字体下载后台任务的种类名（[SettingsCliTaskRegistry]）。
const String kCtlFontDownloadTaskKind = 'font-download';

/// 测试注入点：生产 = 进程级登记表（`fushi_cli task` 命令组查的就是它）。
@visibleForTesting
SettingsCliTaskRegistry ctlFontTaskRegistry = SettingsCliTaskRegistry.instance;

/// 起一个字体下载任务并立即返回（[urls] 与 [recommended] 恰好给一个）。
///
/// 参数错（地址不是 http(s)、推荐表里没有、用途本平台不可用）在起任务前同步抛
/// [ArgumentError]；同一来源已有下载在跑抛 [StateError]（409）。任务：
/// `downloading`（带 0..1 进度，可取消，取消 = 断开 `CancelToken`）→
/// `saving`（写字体目录，不可取消）→ 结果 `{added: [...]}`。
SettingsCliTask startCtlFontDownloadTask(
  CustomFontLibrary lib, {
  List<String>? urls,
  String? recommended,
  required Set<FontTarget> targets,
  String? overrideName,
}) {
  if ((urls == null) == (recommended == null)) {
    throw ArgumentError('url 与 recommended 恰好给一个');
  }
  CustomFontLibrary.checkDownloadRequest(
    urls: urls,
    recommended: recommended,
    targets: targets,
  );
  final String source = recommended ?? urls!.first;
  for (final SettingsCliTask task in ctlFontTaskRegistry.tasks) {
    if (task.kind == kCtlFontDownloadTaskKind &&
        !task.isTerminal &&
        task.detail['source'] == source) {
      throw StateError('「$source」已在下载（任务 ${task.id}）');
    }
  }
  return ctlFontTaskRegistry.start(
    kind: kCtlFontDownloadTaskKind,
    isCancellation: (Object e) => e is CustomFontDownloadCancelled,
    describe: (Object e) => switch (e) {
      CustomFontLibraryException(:final String message) => message,
      ArgumentError(:final Object? message) => '${message ?? e}',
      _ => '$e',
    },
    run: (SettingsCliTask task) async {
      final CancelToken token = CancelToken();
      task
        ..detail['source'] = source
        ..detail['targets'] = <String>[
          for (final FontTarget t in targets) t.name,
        ]
        ..onCancel = () {
          token.cancel('cancelled via control channel');
        };
      task.report(phase: 'downloading');
      void progress(double? value) => task.report(progress: value);
      void commit() {
        task
          ..markCommitting()
          ..report(phase: 'saving');
      }

      final List<CustomFontCatalogRow> added = recommended != null
          ? await lib.downloadRecommended(
              recommended,
              targets: targets,
              cancelToken: token,
              onProgress: progress,
              onCommit: commit,
            )
          : await lib.download(
              urls!,
              targets: targets,
              overrideName: overrideName,
              cancelToken: token,
              onProgress: progress,
              onCommit: commit,
            );
      return <String, Object?>{'added': _records(added)};
    },
  );
}

Future<Object?> _downloadFont(
  SettingsContext c,
  Map<String, String> args,
) async {
  final String url = (args['url'] ?? '').trim();
  final String recommended = (args['recommended'] ?? '').trim();
  final String? name = (args['name'] ?? '').trim().isEmpty
      ? null
      : args['name']!.trim();
  return startCtlFontDownloadTask(
    _lib(c),
    urls: url.isEmpty ? null : _urlsArg(url),
    recommended: recommended.isEmpty ? null : recommended,
    targets: _targetsArg(args, add: true),
    overrideName: name,
  ).toJson();
}

Future<Object?> _updateFont(
  SettingsContext c,
  String id,
  Map<String, String> fields,
) async {
  final CustomFontLibrary lib = _lib(c);
  for (final String key in fields.keys) {
    if (key != 'targets' && key != 'position') {
      throw ArgumentError('修改只认 targets / position（$key 只用于新增）');
    }
  }
  CustomFontCatalogRow? row;
  if (fields.containsKey('targets')) {
    row = await lib.setTargets(id, _targetsArg(fields, add: false));
  }
  final String? position = fields['position'];
  if (position != null) {
    final int? index = int.tryParse(position.trim());
    if (index == null) throw FormatException('position 要是整数：$position');
    row = await lib.move(id, index);
  }
  return row == null ? null : ctlFontRecord(row);
}

Future<Object?> _listRecommended(
  SettingsContext c,
  Map<String, String> _,
) async {
  final List<CustomFontCatalogRow> rows = await _lib(c).list();
  bool installed(String name) => rows.any(
    (CustomFontCatalogRow r) => r.name.toLowerCase() == name.toLowerCase(),
  );
  return <String, Object?>{
    'fonts': <Map<String, Object?>>[
      for (final RecommendedFont font in recommendedFontsCatalog)
        <String, Object?>{
          'name': font.name,
          'nameJa': font.nameJa,
          'license': font.license,
          'description': font.description,
          'installed': installed(font.name),
        },
    ],
  };
}

Future<Object?> _listSystemFonts(
  SettingsContext c,
  Map<String, String> args,
) async {
  final String query = (args['query'] ?? '').trim().toLowerCase();
  final SystemFontList system = await SystemFontCatalog.load();
  final Set<String> added = <String>{
    for (final CustomFontCatalogRow row in await _lib(c).list())
      row.name.toLowerCase(),
  };
  final List<Map<String, Object?>> families = <Map<String, Object?>>[
    for (final SystemFontFamily f in system.families)
      if (query.isEmpty || f.family.toLowerCase().contains(query))
        <String, Object?>{
          'family': f.family,
          'supportsJapanese': f.supportsJapanese,
          'added': added.contains(f.family.toLowerCase()),
        },
  ];
  return <String, Object?>{
    'namesReliable': system.namesReliable,
    'count': families.length,
    'families': families,
  };
}
