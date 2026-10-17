import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 设计系统分派包装（`FushiFilledButton` 等，见
/// `lib/src/utils/components/glass/`）在 MD3 下把原 Material 控件渲染在
/// 自己**下面一层**：key / 祖先查找命中的是包装，`tester.widget<FilledButton>`
/// 直接转型会失败。这里在 [finder] 命中的节点**自身及子树**里取第一个
/// `is T` 的控件——原本就命中 Material 控件的 finder 结果不变，命中包装的
/// 落到它渲染的原控件上；本身就是原类子类的包装（FushiPopupMenuButton /
/// FushiSnackBar）在根上直接命中。
Finder glassUnwrap<T extends Widget>(Finder finder) =>
    glassUnwrapAll<T>(finder).first;

/// [glassUnwrap] 的多结果版（供 `tester.widgetList<T>`）。
Finder glassUnwrapAll<T extends Widget>(Finder finder) => find.descendant(
      of: finder,
      matching: find.byWidgetPredicate((Widget w) => w is T),
      matchRoot: true,
    );
