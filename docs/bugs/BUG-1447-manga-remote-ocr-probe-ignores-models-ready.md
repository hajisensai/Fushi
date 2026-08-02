## BUG-1447 · 远端 OCR probe 只校验 supported 不校验 modelsReady，模型未下载的主机照样可选，白传一整卷才报错

- **报告**：2026-08-02（TODO-2635）
- **真实性**：✅ 真 bug（体验缺陷，非数据错误——报错明确、非静默，但来得太晚）

根因链（全部在 client / UI 侧，**协议不用改**）：

- `hibiki/lib/src/sync/interconnect_manga_ocr_client.dart:196`（修复前）
  `if (capability == null || !capability.supported) continue;` —— 只看 `supported`。
  `modelsReady` 在 `:58` 解析出来后**全 lib 无一处读取**（只有测试断言过一次）。
- `hibiki/lib/src/media/manga/manga_ocr_wizard_dialog.dart:221`（修复前）
  `_remoteAvailable = remote != null;` 与 `:260` `ready: remote != null` —— 于是模型没下载的
  主机既进选项、又能被 `auto` 解析选中当默认引擎。
- 报错真正发生的位置：`hibiki/lib/src/sync/hibiki_manga_ocr_host.dart:242` 的
  `if (!status.allReady) return (503, 'models_not_ready')`，由
  `manga_ocr_wizard_dialog.dart:733-734` 映射成 `t.manga_remote_ocr_not_ready`。
  这条 503 在 **`POST /api/ocr/job/<id>/start`** 才发生——也就是整卷页图已经全部上传完之后。
  没下过 472MB 模型的 Windows 主机，用户白传一整卷才知道不行。

对端能力其实早就报了：`hibiki_manga_ocr_host.dart:130-146` 的 `capability()` 同时返回
`supported` 与 `modelsReady`，两个字段是**同一个 commit `de5103250`（PR#389）**一起进的协议。

### 向后兼容：`modelsReady` 三态

probe 是互联协议的一部分，对端可能是旧版本。三态**必须可区分**，不能压成一个 `bool`：

| 对端响应 | 语义 | 处理 | 理由 |
|---|---|---|---|
| 无 `mangaOcr` 对象 | 真·老 host | 隐藏远程选项（**行为不变**） | 它压根没有这个能力 |
| `modelsReady: true` | 就绪 | 正常可选 | — |
| `modelsReady: false` | 明确未就绪 | 选项**保留但置灰** + 说明原因 | 这才是本 bug 要修的那一态 |
| 有 `mangaOcr`、缺 `modelsReady` | 未知 | **按可用处理**（保持修复前行为），start 阶段兜底 | 现网不存在这种版本；把未知判成 not ready 会让这类对端上本可用的主机凭空消失，等于为一个不存在的版本付真实的功能倒退 |

修复前 `raw['modelsReady'] == true` 把「缺字段」和「明确 false」压成同一个 `false`，所以
必须改成先 `containsKey` 再取值。

- **[x] ① 已修复** — `interconnect_manga_ocr_client.dart`：`modelsReady` 改 `bool?` 三态 +
  `usable` / `modelsMissing` 派生判据；`probe()` 改为**优先返回模型就绪的主机**，一台都没
  就绪时才回退到「支持但未就绪」的那台（顺带修掉「未就绪主机排在前面就把就绪主机永久挡住」
  的选台缺陷）。`manga_ocr_wizard_dialog.dart`：`ready` 只认 `usable`（`auto` 不再落到未就绪
  主机），选项与另外三个引擎同构地 `enabled: false` 置灰而非隐藏，并在选择器下方给出
  `t.manga_remote_ocr_not_ready` 说明原因（复用既有 key，17 语言齐全，无需新增 i18n）。
- **[x] ② 已加自动化测试** —
  `hibiki/test/sync/interconnect_manga_ocr_client_test.dart`（三态可区分 + 优先就绪主机）、
  `hibiki/test/media/manga/manga_ocr_wizard_remote_test.dart`（置灰 + 说明原因 + auto 不落到
  未就绪主机；仅未就绪主机时「无可用引擎」旁必须带原因；缺字段对端仍可用）。
  变异实测：把 `ready: remote != null` 和 `return target` 塞回去，两处各自变红。
- **备注**：交互形态选「置灰 + 说明原因」而非「隐藏」，与向导既有惯例一致——另外三个引擎
  不可用时都是 `enabled: false` 保留，且 `manga_ocr_wizard_dialog.dart:894-897` 已经明写过
  「说清原因，而不是让用户对着一个禁用的按钮猜」这条纪律。隐藏会让用户以为「配对没生效」，
  而真正该做的动作（去主机上下模型）无从得知。
