import 'dart:io';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/media/media_extensions.dart'
    show kImageExtensionsBase;
import 'package:path/path.dart' as p;

import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart';

/// 「外观 › 页面背景」里「图片 / 竖屏图片」与模块单独背景的选图行背后的
/// [ThemeNotifier.importPageBackdropImage] / [ThemeNotifier.importPageBackdropModuleImage]
/// （拍板台 PGpPujl99g）。界面先裁成屏幕比例再导入；这里直接导入给的图片（裁剪是界面
/// 交互，CLI 给的就是用户已备好的图）。
///
/// CLI 侧是 `fushi_cli config backdrop-image <图片> [--portrait] [--module <模块> | --page <页面>]`。
List<CtlRoute> buildPageBackdropCtlRoutes(OpContext context) =>
    buildPageBackdropCtlRoutesFor(() => context.appModel.themeNotifier);

/// 路由路径。
const String kPageBackdropImageCtlPath =
    '/api/admin/appearance/page-backdrop/image';

/// 模块单独背景认的模块 wire（偏好里冻结的写法）。
List<String> get pageBackdropModuleWires => <String>[
  for (final HomeTab tab in HomeTab.values) pageBackdropModuleWire(tab),
];

/// 页面单独背景认的页面 wire（拍板台 xxbbL0j15l）。
List<String> get pageBackdropPageWires => <String>[
  for (final PageBackdropPage page in PageBackdropPage.values) page.wire,
];

/// 路由表本体：主题按回调注入。
List<CtlRoute> buildPageBackdropCtlRoutesFor(
  ThemeNotifier Function() theme,
) => <CtlRoute>[
  CtlRoute.post(kPageBackdropImageCtlPath, (CtlCall call) async {
    final String raw = call.requireString('path').trim();
    if (!p.isAbsolute(raw)) {
      throw CtlFailure.badRequest('path 必须是绝对路径：$raw');
    }
    final File image = File(p.normalize(raw));
    if (!kImageExtensionsBase.contains(p.extension(raw).toLowerCase())) {
      throw CtlFailure.badRequest(
        '不是支持的图片（${kImageExtensionsBase.join(' / ')}）：$raw',
      );
    }
    if (!image.existsSync()) throw CtlFailure.notFound('文件不存在：$raw');
    final bool portrait = call.optBool('portrait') ?? false;
    final String? moduleWire = call.optString('module');
    final HomeTab? module = moduleWire == null
        ? null
        : pageBackdropModuleFromWire(moduleWire) ??
              (throw CtlFailure.badRequest(
                'module 只能是 ${pageBackdropModuleWires.join(' / ')}：$moduleWire',
              ));
    final String? pageWire = call.optString('page');
    final PageBackdropPage? page = pageWire == null
        ? null
        : PageBackdropPage.fromWire(pageWire) ??
              (throw CtlFailure.badRequest(
                'page 只能是 ${pageBackdropPageWires.join(' / ')}：$pageWire',
              ));
    if (module != null && page != null) {
      throw CtlFailure.badRequest('module 与 page 只能给一个');
    }
    final ThemeNotifier t = theme();
    if (page != null) {
      await t.importPageBackdropPageImage(page, image, portrait: portrait);
    } else if (module != null) {
      await t.importPageBackdropModuleImage(module, image, portrait: portrait);
    } else {
      await t.importPageBackdropImage(image, portrait: portrait);
    }
    return <String, Object?>{
      'path': image.path,
      'portrait': portrait,
      'module': ?moduleWire,
      'page': ?pageWire,
    };
  }),
];
