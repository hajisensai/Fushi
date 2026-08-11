## BUG-1537 · 设置行说明文字被压成单行省略号（ellipsis + maxLines:null）
- **报告**：2026-08-11（用户：截图报「描述显示不全」——视频快捷设置里「字幕遮蔽」「尊重字幕自带样式」等行的说明文字只剩开头一行加「…」）
- **真实性**：✅ 真 bug，根因 `fushi/lib/src/utils/components/settings_shared.dart:1958`（`_SettingsLabel` 的说明文字 `Text`）
- **[x] ① 已修复** — `overflow` 改为跟随 `subtitleMaxLines` 联动：`subtitleMaxLines == null ? null : TextOverflow.ellipsis`。null 时交回 `DefaultTextStyle`（clip），说明文字换行整段显示；显式传有限值的密度敏感调用点行为不变。
- **[x] ② 已加自动化测试** — `fushi/test/settings/settings_row_subtitle_wrap_test.dart`（2 条，widget 行为层）
- **备注**：

### 根因

BUG-1184 把 `AdaptiveSettingsRow.subtitleMaxLines` 的默认从 `kSettingsRowSubtitleMaxLines`（3）改成 `null`（= 不钳行数），但说明文字的 `Text` 仍恒传 `overflow: TextOverflow.ellipsis`，代码注释里写的假设是「仍保留 ellipsis，只在调用点显式传有限值时才生效」。

该假设是错的。Flutter/Skia 里 `ellipsis` 配 `maxLines: null` **不是不生效**，而是把整段文字压成单行 + 省略号。同一段文字、同一宽度约束下实测（`RenderParagraph`）：

| overflow | maxLines | 渲染结果 |
|---|---|---|
| `clip` | null | `Size(226, 160)` = 8 行，`didExceedMaxLines=false` |
| `ellipsis` | null | `Size(226, 20)` = **1 行**，`didExceedMaxLines=true` |

于是 BUG-1184 的「修复」把说明文字从 3 行退化到 1 行，比修复前更糟——用户截图里长说明全部只看得到开头。

### 为什么属性层守卫抓不到

`Text.maxLines` 属性本身就是 `null`（"正确"），坏的是渲染结果。同目录既有的 `settings_row_title_max_lines_test.dart` 只断言 widget 属性，结构上抓不到这一类。本 bug 的守卫因此断言 `RenderParagraph` 的真实行数（`size.height / getMinIntrinsicHeight(∞)`）与 `didExceedMaxLines`。

### 验证

- 变异实测：把 `overflow` 退回恒 `TextOverflow.ellipsis`，第一条守卫立刻红（第二条按设计仍绿——显式传有限值时两版行为相同）。
- 同形扫描：全仓传可空 `maxLines` 的 `Text` 只有这一处；`FushiListItem` 的 `titleMaxLines`/`subtitleMaxLines` 都是非空 `int`（1/2），不受影响。
