# 架构审计：ui-design-system

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

设计系统现在用三个互相独立的谓词做分流：isGlassDesign（用户能看到的 Apple/玻璃皮肤）、isCupertinoPlatform 和 isMacosPlatform（两套隐藏皮肤），再加一条正交的 isEinkTheme。偏好归一化只允许 material、glass、auto 三个值，所以两套隐藏皮肤在生产路径上永远走不到，但 87 处 isCupertinoPlatform 分支、macos_ui 依赖和 54 个测试文件还在养着它们。双皮肤靠组件里手写 if 实现：isGlassDesign 出现约 1080 次，分布在 369 个文件里，其中 246 个是 pages/ 和 media/ 下的功能页。功能页因此自己在做皮肤分流，公共组件层没把住这道口子。几个超大文件把两套皮肤写在一起：fushi_material_components.dart 8444 行、settings_shared.dart 5328 行、adaptive_navigation.dart 4790 行、glass_toggles 4791 行、glass_overlays 4799 行。裸 Material 控件残留不多，pages/media 以外约有 80 个裸 Scaffold 和 28 个 FilledButton，所以这块不是主要矛盾。设置 schema 的声明树本身是单一源，渲染、搜索、ctl、伴屏都从它投影，也有 locale 缓存和 section 级 liveListenable，性能面基本健康。真正的缺口在 27 个 body 逃生口和 65 个以上手搭 AdaptiveSettingsSection 的自绘页：ctl 为它们另写了 40 个 CtlBodyPage、约 8000 行的平行声明，设置搜索看不见这些页里的项。快捷键这边，键位存储和冲突检测都在 FushiShortcutRegistry 里，但「哪个页面按什么顺序解析哪些 scope」散在 83 个调用点手写链式调用，coactiveScopes 表和抢占名单是另外两份声明，三者已经对不上。焦点所有权在 6 个媒体页 / SRS 页收敛到了 PageFocusOwnership，但根因（原生 WebView 在指针手势后抢走 OS 焦点）仍要每页按 cause 逐点回收，其余页面还有 74 处裸 requestFocus。动效有 token 与守卫，但守卫只管曲线和字号，不管时长；时长归零有两套 helper，语义不一致。

## dead-hidden-design-systems

**隐藏的 Cupertino / macOS 两套设计系统生产路径永远走不到，却还养着 87 处分支、macos_ui 依赖、整个 CupertinoSettingsRenderer 和 54 个测试文件**

- 类型：死代码；规模 M；价值 high；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/models/theme_notifier.dart:2722-2725 normalizeDesignSystemPreference 只放行 'material' / 'glass'，其它一律归 'auto'；2738 的 designSystem getter 读出来的也是归一化值
- fushi/lib/src/models/theme_notifier.dart:2747-2758 designSystemTheme 的 case 'cupertino' / case 'macos' 因此不可达，FushiDesignSystem 实际只剩 auto 和 material 两个值，而这两个值对所有谓词的结果相同
- fushi/lib/src/utils/adaptive/adaptive_platform.dart:218-236 isCupertinoPlatform 只有 cupertino 返回 true，所以恒为 false；254 起的 isMacosPlatform 同理恒为 false。全仓 isCupertinoPlatform 87 处、isMacosPlatform 7 处（main.dart:3749、home_page.dart:1738、adaptive_widgets.dart:67/129/183、fushi_material_components.dart:1383），12 个文件 import macos_ui，pubspec.yaml:177 还在依赖 macos_ui ^2.2.2
- fushi/lib/src/utils/components/settings_shared.dart:68/196/327/605/917/973/1192/... 一个文件里 19 处 `isGlassDesign(context) && !isCupertinoPlatform(context)` 这类组合判据，每处都要额外排除一个不存在的皮肤
- 设置渲染器的选择逻辑写了三份，顺序还不一样：fushi/lib/src/pages/implementations/fushi_settings_page.dart:83-88 先判 cupertino 再判 glass；module_settings_view.dart:75-79 和 settings/glass_settings_renderer.dart:28-36 先判 glass。三处都要维护永远为 false 的 cupertino 分支，CupertinoSettingsRenderer（241 行）整类不可达
- test/ 下 54 个文件引用 FushiDesignSystem.cupertino / macos，测的是生产上不存在的路径

机制：隐藏皮肤是从用户选项里撤下来的，撤的时候只在偏好归一化这一层截断了入口，枚举、谓词、分支和渲染器都留着。之后每个新组件都照着老组件抄 `glass && !cupertino` 三分支，死分支跟着复制，每新增一个组件就多一份写不出也测不到真实效果的代码。

根本方案：FushiDesignSystem 收成两值（material / glass），删掉 isCupertinoPlatform、isMacosPlatform、useCupertinoAdaptiveControls 以及全部调用分支、CupertinoSettingsRenderer、fushi_macos_theme.dart、macos_ui 的 shell 路径和 pubspec 依赖，54 个测试里测隐藏皮肤的用例一并删掉。设置渲染器的选择只保留 resolveSettingsRenderer 一处，fushi_settings_page 和 module_settings_view 改为调用它。.adaptive 构造器统一按 Material 渲染。偏好键 design_system 冻结不改，归一化逻辑保留用来吃掉旧值。加一条守卫：lib/ 下不得再出现 isCupertinoPlatform / isMacosPlatform 这些符号。删完以后，皮肤分支只剩 glass 与否这一维（eink 是另一条正交维，下一条处理）。

要动：fushi/lib/src/utils/adaptive/adaptive_platform.dart；fushi/lib/src/utils/adaptive/adaptive_widgets.dart；fushi/lib/src/utils/adaptive/fushi_macos_theme.dart；fushi/lib/src/utils/adaptive/adaptive_navigation.dart；fushi/lib/src/utils/components/settings_shared.dart；fushi/lib/src/utils/components/fushi_material_components.dart；fushi/lib/src/settings/cupertino_settings_renderer.dart；fushi/lib/src/settings/glass_settings_renderer.dart；fushi/lib/src/pages/implementations/fushi_settings_page.dart；fushi/lib/src/pages/implementations/module_settings_view.dart；fushi/lib/src/models/theme_notifier.dart；fushi/lib/main.dart；fushi/pubspec.yaml；fushi/test/**

核验说明：代码层面的证据属实，已核验：theme_notifier.dart:2722-2725 只放行 material / glass；FushiDesignSystemTheme 在生产里只有 theme_notifier.dart:3829 一处构造，值取自归一化后的 designSystemTheme，所以 2752-2755 的 cupertino / macos 分支不可达，isCupertinoPlatform（adaptive_platform.dart:218）和 isMacosPlatform（254）在生产上恒为 false。计数也对得上：isCupertinoPlatform 87 处，lib 下 12 个文件 import macos_ui，pubspec.yaml:177 有 macos_ui，test 下 54 个文件引用 cupertino / macos。渲染器选择确实写了三份：fushi_settings_page.dart:83-88 先判 cupertino，module_settings_view.dart:75-79 和 glass_settings_renderer.dart:28-36 先判 glass，前两处都没调用已有的 resolveSettingsRenderer。不成立的是定性：保留这两套不是「撤选项时漏删」。docs/superpowers/plans/2026-07-13-md3-default-macos-shell.md:14 写明「Cupertino/macOS implementations remain in source but hidden」，rules-detail.md:85 和 repo-map.md:42 也都写「仅保留为隐藏内部能力」，这是有记录的设计决定。

方案风险：整删会推翻 rules-detail.md:85 记录的「隐藏内部能力」这条既定决定，按 CLAUDE.md 属于架构方向变更，应先进拍板台让用户确认，不能当成死代码直接删。另外 fushi_settings_page.dart:91 的 scrollController 等处的滚动契约跟着 cupertino 分支走，删分支时要逐处确认 Material 分支的滚动行为不变。

修正后的方案（以此为准）：分两步走。第一步不改变任何行为，可以直接做：fushi_settings_page 和 module_settings_view 改为调用 resolveSettingsRenderer，把三份选择逻辑收成一份；加一条守卫，禁止新组件再写 `isGlassDesign && !isCupertinoPlatform` 这类组合判据，并把这条组合判据收进 isGlassDesign 内部。第二步在拍板台登记一条「是否放弃隐藏的 Cupertino/macOS 渲染器」，写明代价（87 处分支、macos_ui 依赖、54 个测试文件）和收益。用户同意后再整删，并同步改 rules-detail.md:85 和 repo-map.md:42。偏好键 design_system 及其归一化逻辑都保留。

## skin-branch-leaks-into-features

**双皮肤靠「组件里手写 if」：isGlassDesign 约 1080 处、369 个文件，其中 246 个是功能页；公共组件是把两套皮肤写在一起的超大文件**

- 类型：守卫代替结构；规模 XL；价值 high；不改外部行为
- 核验：部分成立

证据：

- grep 统计：isGlassDesign 约 1080 次，出现在 369 个文件里，其中 246 个在 pages/ 和 media/ 下（texthooker_page 15 次、home_page 12 次、media_item_dialog_page 11 次、discovery_layout 11 次、import_dialog_blocks 11 次……），功能页自己在做皮肤分流
- fushi/lib/src/utils/components/fushi_material_components.dart 共 8444 行、74 个顶层类型，FushiCard、FushiListItem、FushiSearchField、FushiTextField、FushiChip、FushiModalSheetFrame、FushiDialogFrame、FushiPageHeader、FushiPageScaffold 都在同一个文件里，各自在 build 里写 `if (isGlassDesign(context))` 分支（如 423/876/1338/1845/2346/2450/2564/2970/3220/3299/4046/5719/6070/6320 行），另有 isEinkTheme 分支（368/730/1236/2302/…）
- fushi/lib/src/utils/adaptive/adaptive_navigation.dart 共 4790 行，_MaterialNavCluster（472）、_AppleLibraryTabBar（1418）、_MaterialFloatingBar（1747）、_GlassTabCapsule（3384）都在同一个文件，还挂着 4 个 part
- fushi/lib/src/utils/components/settings_shared.dart 共 5328 行，AdaptiveSettingsRow（1074）、AdaptiveSettingsSegmentedRow（2218）、GlassSettingsPopUpButton（2845）、AdaptiveSettingsSliderRow（4628）在行级组件内部三向分支
- fushi/lib/src/utils/adaptive/adaptive_platform.dart:195-203 isGlassDesign 只是一个读 ThemeExtension 的自由函数，对谁能调用它没有任何约束；test/ 里也没有限制功能页调用它的守卫（grep test/build 无命中）

机制：皮肤是一个可以在任何地方读取的全局布尔，公共组件又没有「同一契约下两个实现」的结构。功能页一旦需要组件没覆盖的差异，就直接读 isGlassDesign 自己分支。组件作者为了省事也把两套实现写进同一个 build。结果每加一个控件或一处页面差异，都会在调用点新增一个 if。eink 再叠成第三条手写维度，两种皮肤 × eink 的组合散落各处，漏掉一处就是一个视觉 bug（docs/bugs 里有 12 份记录按「玻璃下 / isGlassDesign」出过问题）。

根本方案：(1) 引入 sealed 的 FushiSkin（m3e / apple），在主题根解析一次，eink 作为 FushiSkin 的修饰位，不再是另一个全局函数。(2) 公共组件一律写成「公开契约 + 两个私有实现」：`FushiX` 只负责参数和语义，build 里只有一行 `switch (skin) { m3e => _M3eX(...), apple => _AppleX(...) }`。M3E 实现放 `components/m3e/`，Apple 实现放 `components/apple/`（与现有 glass/ 合并），把 fushi_material_components.dart、settings_shared.dart、adaptive_navigation.dart 按组件拆成「每组件一个契约文件 + 两个实现文件」，原来的大文件删掉。(3) 功能页需要按皮肤区分的只是布局参数（间距、圆角、是否浮动 chrome），把这些收进 FushiSkinMetrics 这类 ThemeExtension token，由页面读 token，不读皮肤。(4) 加棘轮守卫：pages/ 和 media/ 下 isGlassDesign / FushiSkin 的调用次数按文件只减不增，新文件为 0；组件目录以外禁止新增裸 FilledButton / TextButton / Scaffold（目前分别约 28 / 19 / 80 处，同样走棘轮）。以后新增一个控件只改它自己的三个文件，功能页不需要再写分支。

要动：fushi/lib/src/utils/adaptive/adaptive_platform.dart；fushi/lib/src/utils/components/fushi_material_components.dart；fushi/lib/src/utils/components/settings_shared.dart；fushi/lib/src/utils/adaptive/adaptive_navigation.dart；fushi/lib/src/utils/components/glass/*；fushi/lib/src/pages/**；fushi/lib/src/media/**；fushi/test/build/

核验说明：现象成立，但数字偏高约 10%。实测 lib 下 `isGlassDesign(` 979 次，分布在 341 个文件里，其中 pages/ + media/ 有 225 个文件（审计写 1080 / 369 / 246）。超大文件的行数属实：fushi_material_components.dart 8444 行、settings_shared.dart 5328 行、adaptive_navigation.dart 4790 行、glass_toggles 4791 行、glass_overlays 4799 行。test/build 里确实没有限制功能页调用 isGlassDesign 的守卫。不过「同一 build 里两套实现混写」的说法夸大了：抽查 fushi_material_components.dart 的 423、876、1338、1845、2346 行，组件已经是「公开契约 + 私有实现」，各处分支是 `_buildGlassCard` / `_buildGlassTile` / `_buildAppleSuffix` 这类私有方法的分派，glass/ 目录下也已有 22 个 Apple 实现文件。所以缺的是文件级拆分和功能页这一侧的约束，契约结构本身已经有了。

方案风险：(1) 功能页里的分支不全是间距、圆角之类的布局参数。Apple 和 M3E 的 chrome 结构不同，例如视频页另有 video_m3e_chrome 和 video_apple_chrome 两套，FushiSkinMetrics token 收不下这类差异，需要「页面级契约 + 两种实现」。(2) 方案里「eink 作为 FushiSkin 的修饰位」与现有语义冲突：isGlassDesignTheme 在 eink 下强制返回 false（adaptive_platform.dart:202），eink 实际上会让皮肤退回 M3E，并不是叠在皮肤上的修饰。建模时应写成 eink 推导出 m3e 加 eink 调校，否则会把 eink × glass 这个不存在的组合重新引回来。(3) XL 级拆分大文件会与所有正在改这些文件的分支冲突，需要 integration owner 排期。

修正后的方案（以此为准）：保留现有的「契约 + 私有实现」模式，按组件把大文件机械地拆到 components/m3e/ 和 components/apple/，与 glass/ 合并，这一步不改行为。皮肤解析为 FushiSkin 时，eink 写成「强制 m3e 加 eink 调校」的推导规则。功能页的棘轮按实测基线建（225 个文件、979 次），只减不增，新文件为 0；页面结构差异大的，抽出「页面级契约 + 两种实现」，不要硬塞成 token。

## settings-body-escape-hatch-dual-declaration

**设置 schema 的逃生口和自绘页让同一批设置项声明两遍：UI 一份写在 widget 里，ctl 另写 40 个 CtlBodyPage（约 8000 行），设置搜索看不见这些项**

- 类型：缺单一登记源；规模 XL；价值 high；用户可见
- 核验：部分成立

证据：

- fushi/lib/src/ops/ctl_settings_body_items.dart:27-32 原文：「这些页面的设置项不在 schema 的 item 树里（正文是自绘 widget），config 的索引看不到它们……条目只给控制通道用，不进设置页渲染与搜索」
- fushi/lib/src/ops/ctl_settings_body_misc.dart:29-34 用 SettingsCustomItem 声明「应用图标」，但 builder 是 `(SettingsContext _) => const SizedBox.shrink()`；真正的 UI 在 MiscellaneousSettingsPage 里另写了一遍
- fushi/lib/src/ops/ctl_settings_body_plex.dart:17-20 SettingsActionItem 的 onTap 是 `(SettingsContext _) async {}` 空实现，PIN 登录的 UI 在 PlexConfigWidget 里（settings/settings_schema_services.dart:874 `body: (SettingsContext c) => PlexConfigWidget(...)`）
- schema 里有 27 处 `body: (SettingsContext ...)` 逃生口（settings_schema_services.dart:199/218/659/734/811/874、settings_schema_music.dart:381/845、settings_schema_models.dart:102/119 等）；ops/ 下有 20 个 ctl_settings_body_*.dart，共 40 个 CtlBodyPage，其中 ctl_settings_body_anki.dart 1850 行、video_providers 920 行
- settings/ 目录以外有 65 个文件（pages/、media/、anki/）手搭 AdaptiveSettingsSection(…)，这些页的行对 schema、搜索、伴屏都不可见；设置脚手架也有两套：AdaptiveSettingsScaffold（settings_shared.dart:169，7 个文件在用）和 SettingsKitScaffold（settings_kit_core.dart:1583，29 个文件在用）

机制：schema 的 item 类型只覆盖开关、选择、滑条这类简单行。凡是带列表、登录流程、预览网格的页面，就只能走 body 逃生口写整页 widget，或者干脆在 pages/ 里自搭一个 AdaptiveSettingsSection 页面。设置项的「值读写 / 动作」和「怎么画」绑死在同一个 widget 里，ctl 和搜索拿不到，只能在 ops/ 下照着页面逻辑再声明一遍，并靠 ctl_settings_body_*_test 逐页兜着两边一致。页面上改一个选项，ctl 那份不会跟着改，搜索也不会收录。

根本方案：把「设置项 = 数据（id / 标题 / 读 / 写 / 动作 / 可见性）+ 可选的自定义渲染」作为唯一声明形式。给 SettingsItem 增加 `rowBuilder` 和 `SettingsCompositeItem`（列表型或流程型项：声明 cliList 或 cliAction，渲染交给自定义 widget），逃生口页面改成由若干带自定义渲染的 schema item 组成，取消整页 body 回调，原来 widget 里的读写改为从 item 闭包获取。迁完后删除 ops/ctl_settings_body_*.dart 全部 20 个文件和 CtlBodyPage / buildCtlBodyPages，settings_index 直接展平 schema 一棵树，搜索自动收录。pages/ 下 65 个手搭设置页按域收编进对应的 settings_schema_<域>.dart，AdaptiveSettingsScaffold 并入 SettingsKitScaffold。守卫：`SettingsDestination.body` 保留类型以过渡，但设一张只减不增的白名单；settings/ 以外禁止新建 AdaptiveSettingsSection（棘轮）。以后新增一个设置项只改对应的 settings_schema_<域>.dart 一处，设置页、搜索、ctl、伴屏、深链同时生效。ctl 的 id 和 wire key 原样保留。

要动：fushi/lib/src/settings/settings_destination.dart；fushi/lib/src/settings/settings_schema_*.dart；fushi/lib/src/settings/settings_search.dart；fushi/lib/src/ops/settings_index.dart；fushi/lib/src/ops/ctl_settings_body_*.dart；fushi/lib/src/utils/components/settings_shared.dart；fushi/lib/src/settings/settings_kit_core.dart；fushi/lib/src/pages/implementations/**_settings*.dart；fushi/test/ops/ctl_settings_body_*_test.dart

核验说明：属实的部分：ctl_settings_body_items.dart:27-32 原文就是「条目只给控制通道用，不进设置页渲染与搜索」。misc 的 builder 是 SizedBox.shrink，plex 的 onTap 是空 async，两处都属实。ops 下有 21 个 ctl_settings_body_*.dart，构造了 40 处 CtlBodyPage，合计 7301 行。schema 里 `body: (SettingsContext` 有 18 处（审计写 27），settings/ 以外手搭 AdaptiveSettingsSection 的文件实测有 74 个。不成立的部分有两点。第一，「schema 的 item 类型只覆盖简单行」不对：SettingsCustomItem（settings_destination.dart:881）已经有 builder、rowsBuilder（可增删的记录列表）、cliValue、cliList、searchTitle / searchKeywords，这正是方案里要新增的 rowBuilder / SettingsCompositeItem，settings/ 下已有 14 个文件在用。第二，「设置搜索看不见这些项」只对一部分成立：SettingsDestination.bodySearchEntries（settings_destination.dart:89,108-110）专门给自绘正文提供搜索元数据，已有 11 处在用。

方案风险：方案提议新建的机制其实已经存在，照做会造出第三套声明形式。真正缺的是迁移，不是新的 API。ctl 的 id（例如 services.media_server.plex.sign_in）已对外暴露给 fushi_cli，迁移时必须逐条保持不变，并用现有 ctl_settings_body_*_test 做等价对照。把 74 个手搭设置页收编进 schema 会改变页面的分组和渲染，属于用户可见改动，要逐页评估。

修正后的方案（以此为准）：不新增 item 类型，用现有的 SettingsCustomItem / SettingsCustomItem.rows（带 cliValue / cliList）把 body 逃生口页面逐页改写成 schema item。每迁完一页，就删掉对应的 ctl_settings_body_<域>.dart，同时删掉那页的 bodySearchEntries。SettingsDestination.body 的使用点和 ops/ctl_settings_body_*.dart 的文件数各建一条棘轮，只减不增。AdaptiveSettingsScaffold（8 个文件在用）并入 SettingsKitScaffold（31 个文件在用）。settings/ 以外禁止新建 AdaptiveSettingsSection，同样走棘轮。

## shortcut-dispatch-plan-scattered

**快捷键「页面按什么顺序解析哪些 scope」在 83 个调用点手写链式调用，与 coactiveScopes 表、抢占名单三份声明互相对不上，冲突检测靠打补丁**

- 类型：缺单一登记源；规模 L；价值 high；用户可见
- 核验：成立

证据：

- fushi/lib/src/shortcuts/shortcut_action.dart:91-98 注释称 coactiveScopes 是「pages 和 registry 共同依赖的单一真相源」；但 107-170 声明 manga、video 各自独立成组
- fushi/lib/src/media/manga/reader/manga_fushi_page.dart:5046-5066 实际按 manga → universal → global 依次调用 resolveKeyboard，global 并没有进 manga 的 co-active 组，所以用户给 global 动作绑了与 manga 相同的键，冲突检测不报，在漫画页里却被静默遮蔽
- fushi/lib/src/media/video/video_player_shortcuts.dart:971-999 视频页 video → universal → 仅 global 里的全屏键（_resolveGlobalToggleFullscreen，BUG-2462 特例），这条优先级只存在于代码里，冲突检测完全不知道
- fushi/lib/src/shortcuts/shortcut_registry.dart:741 `_keyboardPreemptingScopes`、781 `_gamepadPreemptingScopes` 两份抢占名单是后补的（TODO-1066），注释写明「只改检测不改 coactiveScopes，因为后者同时喂运行时解析」；745-845 的 hasKeyboard / Gamepad / Mouse / WheelConflict 四个函数几乎逐行相同，但只有前两个扫抢占名单
- fushi/lib/src/shortcuts/shortcut_action.dart:103-106 自承「已知限制」：把 Esc 绑给页面动作不会提示冲突，绑完那个页面就退不出去，只能靠 universal_back_test 守卫默认表
- grep 统计：resolveKeyboard / Gamepad / Mouse / Wheel 在 registry 以外有 83 个调用点；home_page、srs_review_page、caret.part、web_browser_page、dictionary_popup_input_bridge、gamepad_service 各自手写 scope 顺序

机制：运行时的优先级（谁先解析、谁兜底、谁抢占）由每个页面用 `??` 链手写，冲突检测则依赖另一张手写的 co-active 表。两边没有共同的数据结构，于是每出现一种新的遮蔽关系（OS 热键抢占、universal 兜底、视频页只认 global 全屏），都只能在检测侧追加一张名单或一句「已知限制」，在解析侧追加一个特例函数，两边一直在漂移。

根本方案：新建 `ShortcutSurface` 枚举（home、reader、manga、video、webBrowser、music、musicPlayer、srsReview、controllerLookup、dictionaryPopup……）。每个 surface 声明一份有序的 `List<ScopeLayer>`，ScopeLayer 由 scope、可选的 action 过滤和 preempts 标记组成，例如 video = [globalExternal(preempt), video, universal, global(only: toggleFullscreen)]。registry 只暴露 `resolve(surface, InputEvent)` 一个入口，键盘 / 手柄 / 鼠标 / 滚轮共用一个泛型实现。冲突检测从同一张表推导：对 scope S 的一个绑定，遍历所有包含 S 的 surface，如果在层序上与更高层的绑定相同，就报「被遮蔽」；与同层的相同就报「冲突」。这样 universal 返回键、抢占名单、视频全屏特例都由表自然覆盖。删除 coactiveScopes、两份 _*PreemptingScopes、四个 has*Conflict 函数，以及各页面里的 `??` 链和 _resolveGlobalToggleFullscreen。守卫：registry 以外禁止调用按 scope 解析的 API（改成私有）。以后新增页面或新增一层优先级，只改 ShortcutSurface 表一处。持久化的 scope / action 名不变。

要动：fushi/lib/src/shortcuts/shortcut_action.dart；fushi/lib/src/shortcuts/shortcut_registry.dart；fushi/lib/src/shortcuts/global_navigation.dart；fushi/lib/src/shortcuts/gamepad_service.dart；fushi/lib/src/shortcuts/mouse_binding_dispatch.dart；fushi/lib/src/media/manga/reader/manga_fushi_page.dart；fushi/lib/src/media/video/video_player_shortcuts.dart；fushi/lib/src/pages/implementations/home_page.dart；fushi/lib/src/pages/implementations/reader_fushi/caret.part.dart；fushi/lib/src/pages/implementations/srs/srs_review_page.dart；fushi/lib/src/pages/implementations/fushi_web_browser_page.dart；fushi/lib/src/pages/implementations/dictionary_popup_input_bridge.dart；fushi/lib/src/pages/implementations/shortcut_settings_page.dart

核验说明：已核验。shortcut_action.dart:117-121 的注释说漫画阅读器「只解析自己的绑定，故自成 co-active 组」，但 manga_fushi_page.dart:5046-5066 实际按 manga → universal → global 顺序调用 resolveKeyboard。global 不在 manga 组里，所以 global 和 manga 撞键时冲突检测不会报，在漫画页里却会被静默遮蔽，注释和代码互相矛盾，这是一个真 bug。video_player_shortcuts.dart:971-999 的 _resolveGlobalToggleFullscreen 特例属实。shortcut_registry.dart:741 和 781 的两份抢占名单属实，注释原文写着「只改检测不改 coactiveScopes，因为后者同时喂运行时解析」。四个 has*Conflict 函数几乎逐行相同，其中 Mouse / Wheel（807-845）不扫 globalExternal。shortcut_action.dart:103-106 自承的 Esc 已知限制属实。83 个调用点这个数字我没有逐个复核。

方案风险：冲突检测改成从表推导「被遮蔽」后，会出现目前被刻意放行的组合。shortcut_action.dart:98-101 写着，书内手柄 B 归有声书「上一句」、在阅读器里吃掉返回键，是 TODO-700 有意要的效果。新表必须能表达「登记在案的有意遮蔽」白名单，否则默认表一上来就带着冲突。还有几类解析并不走 surface 链：GamepadService 在页面 Actions 之前先跑 globalExternal，controllerLookup 在页面派发之前截键，dictionaryPopup 由 WebView 里的 JS 消费。surface 表需要能描述这些前置层，或者明确把它们排除在外。shortcut_channel_wiring_guard_test 现在按源码核 `resolveX(scope:)` 入口，改成私有 API 后要同步改写这条守卫。

修正后的方案（以此为准）：按原方案做 ShortcutSurface 有序层表，补两点：(1) ScopeLayer 支持 `intentionalShadow` 白名单，用来登记 TODO-700 的手柄 B 这类有意遮蔽；(2) GamepadService 的前置 globalExternal 层和 controllerLookup 也写进表。四个 has*Conflict 合成一个泛型实现。漫画页 global 不进冲突检测这个现存 bug 应先按 bug 流程登记，并在重构里用测试钉住。

## native-surface-focus-reclaim-per-page

**原生 WebView 抢 OS 焦点这一个根因，被拆成每页 × 8 种 cause 的逐点回收；PageFocusOwnership 只覆盖 6 个页面，其余页面还有 74 处裸 requestFocus**

- 类型：补丁叠补丁；规模 L；价值 medium；不改外部行为
- 核验：部分成立

证据：

- fushi/lib/src/focus/page_focus_ownership.dart:4-60 FocusReclaimCause 有 8 种（contentReady / gesture / surfaceRemounted / overlayClosed / chromeToggled / popupDismissed / popupRendered / appResumed），注释写明各页判据「天然不同」，留给页面自己写
- fushi/lib/src/focus/webview_key_bridge.dart:3-12 根因写得很清楚：fork 的 flutter_inappwebview_windows 不转发键盘，任一指针手势后 WebView2 就抢走 OS 键盘焦点；本桥只能在 DOM 里截键再回传
- docs/agent/focus-ownership.md:16-26 记载统一之前视频页 29 处、阅读器页 28 处焦点补丁；守卫 media_page_focus_ownership_guard_test 只按文件禁止媒体页裸 requestFocus
- docs/bugs/BUG-3704-srs-review-space-dead-after-grading.md 根因：换卡时 reclaimAfterFrame 只做 Flutter 内的 requestFocus，OS 焦点仍留在离屏的 WebView2，修复改成调用 requestViewFocusChange；docs/bugs 里同时提到 WebView 和焦点的记录约 113 份
- grep 统计：PageFocusOwnership 只在 reader / video / web_video / manga / srs_review / srs_browse(+inspector) 构造；lib/ 下 `.requestFocus()` 仍有 74 处，requestViewFocusChange 只有 2 处

机制：OS 焦点从 FlutterView 转移到原生 surface 是平台视图层的事件，但现在由每个页面在「我猜焦点可能丢了」的时刻按 cause 去补。每新增一个覆盖层、一种宿主（SRS、伴屏、浏览器）或一种手势，就得新增一个回收点或新的 cause 判据。Flutter 内的焦点和 OS 焦点又是两层，只回收前一层的修复（BUG-3704）会再漏一次。

根本方案：(推测，需真机核实 fork 行为) 把回收下沉到平台视图宿主：在 fork 的 flutter_inappwebview_windows 侧，composition 模式下指针转发时不把 OS 键盘焦点交给 WebView2（或在 pointer-up 后由宿主统一把焦点交还 FlutterView），并在 Dart 侧的 custom_platform_view 宿主里做一个 `NativeSurfaceFocusArbiter`。它订阅 FocusManager 与原生 surface 的焦点进出事件，按「当前路由顶层的 PageFocusOwnership.node」统一同时恢复 OS 焦点和 Flutter 焦点。这样 gesture、popupRendered、surfaceRemounted 这几类 cause 不再需要页面调用，PageFocusOwnership 只保留页面语义上的 canOwn 判据（overlayClosed 由 guardOverlay 自动覆盖）。守卫从「媒体页按文件禁止」扩成「lib/ 下 requestFocus 走棘轮，只减不增」。以后新增页面只需要声明一个 ownership node 和它的 canOwn。

要动：packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp；fushi/lib/src/focus/page_focus_ownership.dart；fushi/lib/src/focus/webview_key_bridge.dart；fushi/lib/src/focus/main_window_focus_gate.dart；fushi/lib/src/pages/implementations/reader_fushi_page.dart；fushi/lib/src/pages/implementations/video_fushi_page.dart；fushi/lib/src/pages/implementations/srs/srs_review_page.dart；fushi/lib/src/media/manga/reader/manga_fushi_page.dart；fushi/test/focus/media_page_focus_ownership_guard_test.dart

核验说明：计数属实：lib 下 `.requestFocus()` 74 处；requestViewFocusChange 只在 srs_review_page.dart:197 实际调用（191 行是注释）；PageFocusOwnership 在 reader / video / web_video / manga / srs_review / srs_browse / srs_browse_inspector 构造。FocusReclaimCause 和 BUG-3704 也属实。有两处不成立。第一，审计漏看了已有的根部机制：main_window_focus_gate.dart 文件头写明 BUG-1619 的「根治层」，已经把「Flutter 焦点树能持有焦点 ⟺ 主窗拥有 OS 焦点」做成结构性不变量。fork 的 in_app_webview_manager.cpp:181 附近也已经处理了 Chromium SetFocus 导致主窗失活的问题，回收并不全是逐页做的。第二，74 处 requestFocus 大多是对话框、输入框之间的页面内焦点转移，不是从原生 surface 回收。focus-ownership.md 也专门豁免了 caret.part.dart 这类页面内搬运，所以把全部 requestFocus 都算作这个根因的补丁是错误归类。

方案风险：给全 lib 的 requestFocus 加棘轮会把正常的表单焦点转移也算进去。方案的核心是在 fork 里把 OS 焦点留在 FlutterView，这一步未经验证，审计自己也标了推测。WebView2 里的文本输入（例如浏览器页、texthooker）本来就需要 OS 焦点，不能一律交还给 FlutterView，否则网页里的输入框会打不了字。

修正后的方案（以此为准）：先在 Windows 真机上核实一件事：在 composition 模式下，WebView2 拿到焦点后能不能由宿主在 pointer-up 后按「命中的是否可编辑 DOM 元素」决定是否交还焦点。NativeSurfaceFocusArbiter 应建在 main_window_focus_gate 这层现有不变量之上，并把 OS 焦点和 Flutter 焦点一起恢复（requestViewFocusChange），把 srs_review_page.dart:191-197 的单点实现收编进去。守卫只扫那些持有原生 surface（WebView / media_kit）的宿主页，不扫全 lib。

## motion-gating-two-helpers

**动效时长归零有两个语义不同的 helper（einkSafeDuration 不看「减少动态效果」），守卫也没有管时长：组件层还有约 40 处裸 Duration 动画**

- 类型：缺单一登记源；规模 S；价值 medium；用户可见
- 核验：成立

证据：

- fushi/lib/src/utils/adaptive/adaptive_platform.dart:206-210 einkSafeDuration 只看 eink，注释写「共享组件与页面级 Animated* 统一走这里」
- fushi/lib/src/utils/components/fushi_motion_tokens.dart:520-528 fushiMotionEnabled / fushiMotionDuration 同时看 eink 和 MediaQuery.disableAnimations，CLAUDE.md 规定时长只能取它
- einkSafeDuration 有 23 处调用（video_m3e_chrome.dart:224、video_apple_chrome.dart:200、browse_page.dart:356/1321、updates_dashboard_banner.dart:95/99 等），这些动画在系统开启「减少动态效果」时照样播放
- utils/components、utils/adaptive、settings 下约 40 处 `duration: Duration(milliseconds: N)` 裸写，例如 fushi_icon_button.dart:945/948、fushi_m3e_overlays.dart:60-69、fushi_floating_chrome.dart:1571、fushi_expressive_progress.dart:259/517
- test/build/motion_type_token_guard_test.dart 文件头说明守卫只棘轮管 Curves.xxx 和裸 fontSize，不管时长

机制：「eink 下归零」是先有的，「减少动态效果」是后加进 fushiMotionDuration 的，但旧 helper 没有合并或删除，两个名字都像正确答案，调用点随手挑一个。守卫只覆盖了曲线和字号，时长常量可以随意写，于是 token 体系在时长这一维上没有被强制执行。

根本方案：删除 einkSafeDuration，23 处调用改为 fushiMotionDuration（进度条那条 einkSafeProgressValue 保留，它的语义不同）。在 FushiMotion / context.fushiMotion 上补齐组件实际在用的时长档位（press、hover、overlay 进出），把约 40 处裸时长换成 token。motion_type_token_guard_test 增加第三张棘轮表：lib/ 下 `Duration(milliseconds:` 用作 duration / reverseDuration / animationDuration 实参时只减不增。以后组件写动画只能从 token 取时长，归零策略只在 fushiMotionEnabled 一处。

要动：fushi/lib/src/utils/adaptive/adaptive_platform.dart；fushi/lib/src/utils/components/fushi_motion_tokens.dart；fushi/lib/src/utils/components/*.dart；fushi/lib/src/media/video/video_m3e_chrome.dart；fushi/lib/src/media/video/video_apple_chrome.dart；fushi/lib/src/pages/implementations/browse_page.dart；fushi/test/build/motion_type_token_guard_test.dart

核验说明：已核验。adaptive_platform.dart:206-210 的 einkSafeDuration 只看 eink；fushi_motion_tokens.dart:519-527 的 fushiMotionEnabled / fushiMotionDuration 同时看 eink 和 maybeDisableAnimationsOf。einkSafeDuration 在 lib 里有 23 处调用。motion_type_token_guard_test.dart 的文件头写明它只棘轮管 Curves 和 fontSize。还有一条直接的 bug 证据：updates_dashboard_banner.dart:91 的注释写着「减弱动态效果 / 墨水屏下零时长」，94-99 行实际调用的却是只看 eink 的 einkSafeDuration，系统开了减少动态效果时动画照样播放。约 40 处裸 Duration 这个数字我没有逐个复核。

方案风险：popupDismissAnimationDuration（swipe_dismiss_wrapper.dart，BUG-2418）是「用户开关 + einkSafeDuration」的组合入口，改成 fushiMotionDuration 后，系统的减少动态效果也会让弹窗滑关的补间归零，这是用户可见的行为变化，需要确认能接受。时长棘轮如果只按 `Duration(milliseconds:` 字面扫，会误伤 Timer / debounce 这类非动画用途，必须像方案写的那样只匹配 duration / reverseDuration / animationDuration 实参。

修正后的方案（以此为准）：同意原方案，补一点：BUG-2418 的入口要显式改写成「用户开关 → fushiMotionDuration」，并在该 bug 文件里更新说明。updates_dashboard_banner.dart:94-99 的注释和代码不符，按 bug 登记并加测试。

## 核验补充（审计漏掉的）

- 漫画页快捷键是一个现存的真 bug，审计只把它当作重构动机提了一句，没有登记。shortcut_action.dart:117-121 声称 manga 自成一组、只解析自己的绑定，但 manga_fushi_page.dart:5060-5065 还会解析 global。用户把 global 动作改到某个 manga 已用的键时，冲突检测不报，在漫画页里却会被 manga 动作静默遮蔽。这条应先按 BUG 流程登记并修复，不必等 ShortcutSurface 重构。
- hasMouseConflict 和 hasWheelConflict（shortcut_registry.dart:807-845）不扫 globalExternal，键盘和手柄那两份（741/781）都扫。如果 globalExternal 将来开放鼠标或滚轮通道，又会漏报。这个不对称目前只靠注释维持，没有守卫。
- updates_dashboard_banner.dart:91-99 的注释写「减弱动态效果 / 墨水屏下零时长」，实际用的是只看 eink 的 einkSafeDuration，注释与行为不符，开了系统减少动态效果时横幅仍有动画。
- resolveSettingsRenderer（glass_settings_renderer.dart:28）已经是单一入口，但 fushi_settings_page.dart:83-88 和 module_settings_view.dart:75-79 没有调用它，而是各自内联，判断顺序还不一样。这一步不改任何行为，可以独立先做，不必等隐藏皮肤的去留拍板。
- 重叠的机制已经存在，审计没有引用：SettingsCustomItem.rows、cliValue / cliList（settings_destination.dart:881 起）和 SettingsDestination.bodySearchEntries（89、108-110 行）。这意味着设置逃生口问题的根因是迁移停滞，缺少「body 只减不增」的棘轮，并不是 schema 表达力不够。
