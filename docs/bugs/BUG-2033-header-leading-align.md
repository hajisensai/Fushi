## BUG-2033 · 页头返回箭头与标题垂直未对齐
- **报告**：2026-09-02（用户：截图新手引导页，「左上角文字和返回箭头没对齐，各个地方都修复一下」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/components/fushi_material_components.dart:2146`（页头整行 `CrossAxisAlignment.start` 顶对齐）+ 同文件 leading 处写死 `top: tokens.spacing.gap / 2`。

  页头一行里两侧的「视觉中心」高度天然不同：`BackButton` 是 48 高的 M3 图标按钮，图标中心距顶 24；标题 `tokens.type.pageTitle`（headlineMedium 22px × 行高 1.27）的行盒中心距顶约 14。顶对齐让两者顶边齐平，中心差约 14px——箭头恒比标题低一截。原实现给 leading 补 `gap / 2 = 4` 的顶部内边距试图凑，方向还凑反了（差从 10 拉到 14）。动作键同理（图标中心 20~24 vs 标题中心 14）。

  这个差随字号档位、`textScaler`、按钮尺寸变化，任何常数都只在一种组合下正确 —— 属于「拿常数补对齐」的坏结构，不是数值调错。

- **[x] ① 已修复** — 删掉 `centerVertically` 这个特例开关（原本只有 `customTitle` 分段导航页头享受居中），整行统一 `CrossAxisAlignment.center`；leading 的方向性内边距只留水平 `end`，垂直位置交给行对齐；动作行内部也改为居中（同一行混着纯图标键与带标签药丸时不再顶对齐）。判据不含任何常数：Row 按两侧实际高度居中，字号/缩放/按钮尺寸怎么变都成立。带副标题或标题折行时，前导键落在整个标题块中心（ListTile / 两行 AppBar 的既有做法）。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_page_header_leading_alignment_test.dart`（4 条渲染几何断言，非源码扫描）：单行标题箭头中心 == 标题中心；`textScaler = 1.6` 下仍相等（写死常数的实现在这一档必失配）；动作键中心 == 标题中心；带副标题时箭头中心 == 标题块（标题顶→副标题底）中心。四条均经变异实测：把整行改回 `CrossAxisAlignment.start` 后全部变红。
- **备注**：修的是共享组件 `FushiPageHeader` / `FushiPageScaffold`，全仓走这套页头的页面一次性生效。
