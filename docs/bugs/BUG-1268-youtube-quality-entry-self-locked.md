## BUG-1268 · YouTube 画质入口自锁：设置面板画质行永不显示

- **报告**：2026-07-31（用户：「app内对油管适配极差 …… 不能调画质」）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/settings/settings_schema_video.dart:977-982`（旧代码），
  与 `hibiki/lib/src/pages/implementations/video_hibiki/quality.part.dart:83-85` 判据不一致。

### 根因

设置面板里「播放」分类的画质入口行 `video.player.quality_entry` 的显示谓词是**两个条件与一起**：

```dart
final int count = videoQuickSettingsHostOf(c)?.qualityOptionCount ?? 0;
return count > 0 && videoQuickSettingsHostOf(c)?.onOpenQuality != null;
```

而 `qualityOptionCount` 对 YouTube 是**懒解析**结果：

```dart
int get _qualityOptionCount =>
    _youtubeVariants.isNotEmpty ? _youtubeVariants.length : _hlsVariants.length;
```

`_youtubeVariants` 只有在 `_showQualityMenu()` → `_ensureYoutubeVariantsLoaded()` 跑完
一次 `getManifest` 之后才非空，而 `_showQualityMenu` 又**只能从这一行点进去**。于是形成自锁：

- 要显示入口 → 需要 `qualityOptionCount > 0`
- 要 `qualityOptionCount > 0` → 需要先解析档位
- 要解析档位 → 需要点这一行入口

结果：**YouTube 播放时设置面板里的画质行永远不出现**。HLS master 不受影响（`_hlsVariants`
在载入时由 `_detectHlsVariantsForLoad` 同步探测填好，进面板时已 `> 0`）——所以这个 bug 只在
YouTube 上暴露。

同一功能的另一个入口（桌面端右键菜单，`video_hibiki_page.dart:6503`）用的却是
`_hasQualityMenu`（= `_hlsVariants.isNotEmpty || _isYoutubeStream`，懒解析前就为 true），
判据本就与设置面板不一致。所以现象是：**桌面端还能靠右键菜单进，移动端（Android/iOS 无右键）
彻底没有任何调 YouTube 画质的入口**。

非解析失效：实测 androidVr `getManifest` 正常返回
`dQw4w9WgXcQ` → `[2160,1440,1080,720,480,360,240,144]` 共 8 档，档位数据一直是好的，
纯粹是入口显示不出来。

### 修复

- **[x] ① 已修复** — `settings_schema_video.dart`：显示谓词只看 `onOpenQuality != null`，
  去掉自锁的 `qualityOptionCount > 0`。页面侧 `onOpenQuality` 已经是
  `_hasQualityMenu ? _showQualityMenu : null`，本身就是「有画质菜单」的准确语义，
  两个入口的判据就此统一（消除特殊情况，而不是给 YouTube 加特例分支）。

### 测试

- **[x] ② 已加自动化测试** — `hibiki/test/settings/video_quality_entry_visibility_test.dart`：
  钉住「懒解析前 `qualityOptionCount == 0` 但 `onOpenQuality` 已接线 → 入口行可见」，
  并反向钉住「无画质菜单（`onOpenQuality == null`）→ 行隐藏」。变异实测：把谓词改回
  `count > 0 && ...` 时该测试失败。

- **备注**：同轮修复见 [BUG-1267](BUG-1267-youtube-caption-track-labels-ambiguous.md)（同一份用户报告的字幕轨部分）。
