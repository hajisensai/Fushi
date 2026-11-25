package app.fushi.reader;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/// 固定快捷方式（pinned）命名空间的所有权判定，纯 Java、无 Android 依赖，供 JVM 单测。
///
/// 系统的 pinned 列表是整个 app 共用的：长按图标菜单（[AppShortcutsHelper]）和自定义
/// 应用图标（[IconSwitchHelper] 的 `hibiki_custom_icon`）都往里放。[AppShortcutsHelper]
/// 只能处置**自己发布过**的 id——Dart 本次下发的、模块被关掉的、以及曾经发布过后下线的
/// （[RETIRED_IDS]）。不认识的 id 一律不碰（BUG-4326：此前把不在本次下发列表里的
/// pinned 全当「已下线」置灰，连自定义图标也一起禁掉了）。
final class AppShortcutOwnership {
    private AppShortcutOwnership() {}

    /// 对一条 pinned 快捷方式该做什么。
    enum PinnedAction {
        /// 本次仍在提供，或不归应用快捷方式管：不动。
        KEEP,
        /// 仍是应用快捷方式、只是模块被关掉：置灰并显示「模块已关闭」。
        DISABLE_MODULE_OFF,
        /// 曾发布过、已下线的应用快捷方式：置灰，用启动器默认文案。
        DISABLE_RETIRED,
    }

    /// 曾作为长按图标菜单发布过、现已下线的 id（`AppShortcut` 早期的 games / settings，
    /// 见 200fc13b41）。只增不删：已固定到桌面的旧快捷方式一直要能被认领并置灰。
    static final Set<String> RETIRED_IDS =
        Collections.unmodifiableSet(new HashSet<>(Arrays.asList("games", "settings")));

    /// [offered]：Dart 本次提供的全部 id；[moduleDisabled]：仍是应用快捷方式但模块被关掉的 id。
    static PinnedAction classifyPinned(
        String id, Set<String> offered, Set<String> moduleDisabled) {
        if (id == null || offered.contains(id)) return PinnedAction.KEEP;
        if (moduleDisabled.contains(id)) return PinnedAction.DISABLE_MODULE_OFF;
        if (RETIRED_IDS.contains(id)) return PinnedAction.DISABLE_RETIRED;
        return PinnedAction.KEEP;
    }
}
