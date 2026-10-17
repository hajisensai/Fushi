// ignore_for_file: deprecated_member_use
//
// Flutter 3.47 把 Material / Cupertino 拆成 pub 包 material_ui / cupertino_ui，
// 本仓已整体迁移（tool/migrate_design_widgets.sh）。但仍有第三方依赖没迁移、
// 继续用 SDK 内的 package:flutter/material.dart / cupertino.dart 渲染组件：
//   - flutter_markdown 0.6.x（更新日志 / 更新弹窗的 MarkdownBody、SelectableText）
//   - liquid_glass_widgets（玻璃组件全是旧 Cupertino：CupertinoTextField 等）
//   - macos_ui（隐藏的 macOS renderer，Tooltip 等仍用旧 Material）
//   - hotkey_manager / window_manager / flutter_html / pdfrx 等只读旧 Theme 的包
// 新旧两套是**不同的类型**：旧组件看不见 material_ui 的 Theme / Material /
// MaterialLocalizations，会退回默认主题，或在 debug 下直接因「No Material
// widget found」「No MaterialLocalizations found」断言失败。
//
// 这里是本仓唯一一处同时引用新旧两套的地方，把 app 根上的新主题 / 本地化
// 桥给旧组件：
//   - CupertinoUiCompatibilityBridge：新 CupertinoTheme → 旧 CupertinoTheme +
//     旧 CupertinoLocalizations；
//   - MaterialUiCompatibilityBridge：新 ThemeData → 旧 ThemeData + 旧
//     MaterialLocalizations；
//   - 一层透明的旧 Material：满足旧 TextField / InkWell 的「祖先必须有
//     Material」要求。textStyle 取当前 DefaultTextStyle，所以不改变任何文字样式；
//     旧 InkWell 的水波纹会落在这层根 Material 上（被页面盖住、看不见），只是
//     降级不是崩溃。
// 清理条件：上面这些依赖都迁到 material_ui / cupertino_ui（或被替换）后整文件
// 删除，并把三个 entry point（main / popup_main / floating_dict_main）的包裹
// 一并去掉。守卫 test/build/design_widgets_import_guard_test.dart 的白名单
// 同步收缩。
import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoUiCompatibilityBridge;
import 'package:flutter/material.dart' as legacy show Material, MaterialType;
import 'package:material_ui/material_ui.dart';

/// 让未迁移到 material_ui / cupertino_ui 的第三方组件读到 app 的主题与本地化。
///
/// 必须放在 app 的 [Theme]、[CupertinoTheme] 与 [Localizations] **之下**
/// （即 `MaterialApp.builder` 里、自定义 [CupertinoTheme] 之内），并包住
/// Navigator，这样所有路由、对话框与 overlay 都在桥之下。
class LegacyDesignCompatibility extends StatelessWidget {
  /// 包住 [child]。
  const LegacyDesignCompatibility({super.key, required this.child});

  /// 被桥接的子树（通常是 Navigator）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CupertinoUiCompatibilityBridge(
      child: MaterialUiCompatibilityBridge(
        child: legacy.Material(
          type: legacy.MaterialType.transparency,
          textStyle: DefaultTextStyle.of(context).style,
          child: child,
        ),
      ),
    );
  }
}
