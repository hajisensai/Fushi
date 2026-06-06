import 'package:flutter/widgets.dart';

import 'package:hibiki/src/media/drag_drop/card_hit_test.dart';

/// 收集当前屏上所有可作为字幕/音频拖放目标的卡片，提供按落点命中测试。
/// 范型 T = 卡片元数据（书卡用 String bookKey，视频卡用 VideoBookRow）。
class CardDropRegistry<T> {
  final Map<GlobalKey, T> _entries = <GlobalKey, T>{};

  void register(GlobalKey key, T meta) => _entries[key] = meta;
  void unregister(GlobalKey key) => _entries.remove(key);

  /// 用 [globalPosition]（屏幕坐标）命中卡片，返回 meta 或 null。
  T? hitTest(Offset globalPosition) {
    final List<CardRect<T>> rects = <CardRect<T>>[];
    for (final MapEntry<GlobalKey, T> e in _entries.entries) {
      final BuildContext? ctx = e.key.currentContext;
      if (ctx == null) continue;
      final RenderObject? ro = ctx.findRenderObject();
      if (ro is! RenderBox || !ro.attached) continue;
      final Offset topLeft = ro.localToGlobal(Offset.zero);
      rects.add(CardRect<T>(rect: topLeft & ro.size, meta: e.value));
    }
    return hitTestCards<T>(rects, globalPosition);
  }
}

/// 把 registry 下发给子树卡片。
class CardDropScope<T> extends InheritedWidget {
  const CardDropScope(
      {required this.registry, required super.child, super.key});

  final CardDropRegistry<T> registry;

  static CardDropRegistry<T>? maybeOf<T>(BuildContext context) {
    final CardDropScope<T>? scope =
        context.dependOnInheritedWidgetOfExactType<CardDropScope<T>>();
    return scope?.registry;
  }

  @override
  bool updateShouldNotify(CardDropScope<T> oldWidget) =>
      registry != oldWidget.registry;
}

/// 包住一张卡片：挂 GlobalKey，并在生命周期内向最近的 CardDropScope 注册/注销自己。
class CardDropZone<T> extends StatefulWidget {
  const CardDropZone({required this.meta, required this.child, super.key});

  final T meta;
  final Widget child;

  @override
  State<CardDropZone<T>> createState() => _CardDropZoneState<T>();
}

class _CardDropZoneState<T> extends State<CardDropZone<T>> {
  final GlobalKey _key = GlobalKey();
  CardDropRegistry<T>? _registry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final CardDropRegistry<T>? next = CardDropScope.maybeOf<T>(context);
    if (!identical(next, _registry)) {
      _registry?.unregister(_key);
      _registry = next;
      _registry?.register(_key, widget.meta);
    }
  }

  @override
  void didUpdateWidget(CardDropZone<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.meta != widget.meta) {
      _registry?.register(_key, widget.meta);
    }
  }

  @override
  void dispose() {
    _registry?.unregister(_key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: _key, child: widget.child);
}
