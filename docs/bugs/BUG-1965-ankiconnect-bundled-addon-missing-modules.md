## BUG-1965 · 内置 AnkiConnect 插件包漏打 web/edit/util 三个模块，装上必 ImportError
- **报告**：2026-08-30（查 BUG-1964 时顺带发现，非用户报告）
- **真实性**：✅ 真 bug。`fushi/assets/anki/ankiconnect.ankiaddon` 入库时只打了 3 个文件：
  ```
  __init__.py 62936   config.json 182   config.md 114
  ```
  而这份 `__init__.py`（与上游 `FooSoft/anki-connect@4064fa142785975255457abd6a496015f5b71f38` 的 `plugin/__init__.py` **逐字节相同**）顶部就写着：
  ```python
  from .web import format_exception_reply, format_success_reply
  from .edit import Edit
  from . import web, util
  ```
  `web.py` / `edit.py` / `util.py` 三个同级模块**一个都没打进去**。新手引导的「一键安装 AnkiConnect」（`fushi/lib/src/pages/implementations/onboarding_wizard_page.dart:307` → `installAnkiConnectAddon`，`fushi/lib/src/anki/ankiconnect_addon_installer.dart:65`）解压的就是这份字节，Anki 下次启动加载插件时必 `ImportError`，AnkiConnect 根本不会开始监听——用户只看到「连不上 Anki」，看不出插件压根没起来。
  （设置页那条「代装 AnkiConnect」走的是另一条路：`AnkiConnectInstaller` 从 AnkiWeb 下完整裸包交给运行中的 Anki，不受此影响。受影响的只有 onboarding 的内置资产路径。）
- **原守卫为什么没抓到**：`fushi/test/anki/ankiconnect_addon_installer_test.dart` 的 “bundled asset is a valid addon zip” 只断言 `__init__.py` / `config.json` 存在、含 `anki_version` / `8765`——查的是「文件在不在、字符串对不对」，结构上抓不到「少打了包内模块」。
- **[x] ① 已修复** — 按同一 upstream commit 补齐 `web.py` / `edit.py` / `util.py`，重新打包 `fushi/assets/anki/ankiconnect.ankiaddon`（6 个文件，确定性时间戳；`__init__.py` / `config.json` / `config.md` 的 sha256 与修复前一致，只是补了缺的三个）。
- **[x] ② 已加自动化测试** — 同文件新增 “bundled asset ships every module its `__init__.py` imports”：扫 `__init__.py` 里的相对导入（`from .mod import …` / `from . import a, b`）反推出模块名，逐个断言包内存在 `<mod>.py` 或 `<mod>/`。判据是**行为反推**而非硬编码文件清单，换上游版本、模块增减后照样成立；并断言解析结果非空，防止正则跟不上上游写法后守卫空转。
- **备注**：真机端到端（装进真 Anki、确认 AnkiConnect 起来并应答 `version`）未做，本轮只到「包内容完整、守卫能抓」。
