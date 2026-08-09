# TMDB logo asset (third-party trademark — do not edit)

TMDB 署名是**合约义务**（Terms of Use 第 3 节：署名文字 + logo），不是可选致谢。

本目录三个文件：

| 文件 | 角色 | 是否打包进 app |
|---|---|---|
| `blue_square_1.svg` | TMDB 官方原图，**逐字节未加工** | 否（provenance 真相源） |
| `logo_tmdb.png` | 由上面那张 SVG 栅格化而来，实际渲染用 | 是 |
| `rasterize.html` | 栅格化配方（可复现） | 否 |

## 原图 provenance

| 项 | 值 |
|---|---|
| 来源页 | <https://www.themoviedb.org/about/logos-attribution> |
| 变体 | Primary short (blue) |
| 直链 | `https://www.themoviedb.org/assets/2/v4/logos/v2/blue_square_1-5bdc75aaebeb75dc7ae79426ddd9be3b2be1e342510f8202baf6bffa71d7f5c4.svg` |
| SHA-256 | `5bdc75aaebeb75dc7ae79426ddd9be3b2be1e342510f8202baf6bffa71d7f5c4` |
| 字节数 | 2232 |
| viewBox | `0 0 190.24 81.52`（宽高比 ≈ 2.33366:1） |
| 取图日期 | 2026-08-02 |

TMDB 的资产 URL 用文件内容摘要命名（Rails asset digest）——上表 SHA-256 与直链文件名里
那串**完全相同**，这就是「入库的是官方原图、零加工」的可验证证据。

## 为什么还要一张 PNG（而不是直接渲染 SVG）

Flutter 没有内置 SVG 渲染；唯一现实选项 `flutter_svg` 明确**不支持 CSS**
（README: "choose Presentation Attributes instead of Inline CSS because CSS is not fully
supported"；`vector_graphics_compiler` 把 `<style/>` 归入 unhandledElement）。而 TMDB 这
张原图恰好把唯一的填充写在 CSS 类里：

```svg
<style>.cls-1{fill:url(#linear-gradient);}</style> … <path class="cls-1" …/>
```

实测（本任务留证）：`flutter_svg` 解析后渐变丢失，整个标识渲染成**纯黑** 9397 px。把黑色
的 TMDB 标识发出去本身就是「改色」，比不放 logo 更违反条款。因此改为：矢量原图照旧逐字节
入库存证，运行时渲染一张由它栅格化出的 PNG。栅格化只做尺寸映射，不改色/不改比例/不翻转/
不旋转/不裁剪/不加边框滤镜。

## 栅格化配方（可复现）

用 Chromium 内核（Blink，正确支持 SVG 内 CSS）离屏渲染 `rasterize.html`：

```sh
msedge --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=1 --default-background-color=00000000 \
  --window-size=224,96 --screenshot=logo_tmdb.png <本目录>/rasterize.html
```

- 输出 224×96 RGBA，背景全透明；window-size 与 `<img>` 尺寸相同，所以**没有任何裁剪**。
- 224:96 = 7:3 = 2.33333，与原图 2.33366 相差 0.014%（24dp 展示下 < 0.01 px），是栅格化取整
  的固有下限，非人为改比例。渲染侧另有 `BoxFit.contain` 兜底，任何情况下都不会拉伸。
- 224×96 覆盖到 DPR 4（24dp × 4 = 96 px）1:1，再高只会轻微软化，不会失真。
- 实测该 PNG 全部不透明像素落在 R∈[0,143] G∈[179,206] B∈[161,229]，正好是 TMDB 官方渐变
  三色 `#90cea1 → #3cbec9 → #00b3e5` 的端点区间，零越界像素——配色与原图一致。

## 硬规则

- **禁止**改色、改比例、翻转、旋转、裁剪、加边框、加滤镜；也**禁止**手改 `blue_square_1.svg`
  （包括为绕开 flutter_svg 的 CSS 限制而把 `fill` 内联进 path——那会毁掉上面的哈希证据链）。
  要换变体就从来源页重新下载另一份原图，更新本表、重跑配方、同步守卫。
- 展示尺寸不得比应用自身 logo 更显眼（当前 24dp 高，与设置行图标徽标同量级）。
- logo 与 i18n key `about_tmdb_attribution` 是一对：**删 key 前不要先删署名，反之亦然**；
  要走一起走（移除 TMDB 刮削含内置 key 时）。
- 守卫：`fushi/test/settings/tmdb_attribution_test.dart`。
