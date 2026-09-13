## BUG-2514 · コミコ源章节阶段报 Not Found
- **报告**：2026-09-13（用户贴诊断：`stage: chapters / source: コミコ / MihonRuntimeException(BRIDGE_HTTP_500): Not Found`，栈顶 `q.chapterListParse`）
- **真实性**：✅ 真 bug，但根因在 **keiyoushi 扩展侧**（`ja/comico` v1.4.2 = 最新版），本仓桥没有改坏请求。
  - 抛出点：`extensions-source/src/ja/comico/.../Comico.kt:119-125` `parseData()`：HTTP 200 但 JSON `result.code != 200` 时 `throw Exception(status(code))`，404 → "Not Found"；`chapterListRequest` = `GET api.comico.jp` + `manga.url` + `/episode`（:76），而 `Dto.kt:65` **无视作品 `type` 字段硬编码** `url = "/comic/$id"`。
  - 真实请求复现（经代理、按扩展方式带 `X-comico-*` 签名头）：trending 榜里混有 `type: magazine_comic`（KADOKAWA 分冊版等）的作品；`GET /comic/209156/episode` → `result.code=404 "コンテンツが見つかりません。"`（与用户报错逐字对应），`GET /magazine_comic/209156/episode` → 200、64 章。地区/登录/请求头全排除：缺签名头是 `code=400`、`Accept-Language` 非 ja 是 `code=500`，都不是 404；匿名非日本出口也能 200。另一种同样 404 的情形是该 id 已下架/未公开。
  - `magazine_comic` 的章节正文是加密 epub（`chapterFileFormat: "epub"`，无 `chapter.images`），扩展 `pageListParse` 只读 `chapter.images`——即便修了路由前缀也拿不到页，完整支持要下载解密解包 epub。
  - 本仓桥核对：`third_party/m_extension_server/upstream_src/.../MihonInvoker.kt:268-286,472-474` manga.url 原样；overlay `NetworkHelper.kt` 只加代理策略/日志/Cloudflare 拦截器；Dart `mihon_bridge_runtime.dart:153-171` / `mihon_models.dart:166-176` 保留原 url。
- **[ ] ① 未修复** — 根因在上游扩展，本仓无处可修。可做：给 keiyoushi 提 issue/PR（`ContentInfo` 增 `type` → `url = "/$type/$id"`，`pageListParse` 增 epub 分支；短期至少在列表阶段过滤 `type != "comic"` 免得点进去才炸）。**是否代表用户去上游开 issue 需用户点头**。
- **[ ] ② 未加自动化测试** — 无本仓代码改动。
- **备注**：`BRIDGE_HTTP_500` 只是桥把扩展抛的普通 `Exception` 包成 500 的外观，"Not Found" 已是扩展原话；诊断文本已能定位到源与阶段，展示层不动。探针脚本 `C:\Users\wrds\AppData\Local\Temp\comico_probe.py`（`python comico_probe.py id <id>` 可对某个作品 id 复测，不入库）。
