<h3 align="center">hibiki</h3>
<p align="center">Android 日语沉浸式阅读器 — EPUB + 词典 + Anki + 有声书同步</p>

---

# 概述

**hibiki** 是一款面向日语学习者的 Android 阅读应用，目标对标 iOS [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)。

核心功能：
- 📖 内嵌 ッツ Ebook Reader 渲染 EPUB，点按即查词
- 📘 Yomitan 格式词典，支持音调与词频信息
- 🃏 一键导出 AnkiDroid 制卡（含上下文句子与音频）
- 🎧 有声书同步（Sasayaki）：SMIL / SRT / LRC / VTT / ASS 字幕 → EPUB 文本对齐 → 跟读高亮

# 技术栈

| 层 | 技术 |
|---|---|
| 框架 | Flutter 3.41.6 / Dart 3.11.4 |
| 阅读器 | ッツ Ebook Reader（WebView，[独立 fork](https://github.com/hdjsadgfwtg/ttu-fork)） |
| 存储 | Isar + Hive |
| NLP | MeCab + Ve（分词 / deinflection） |
| 制卡 | AnkiDroid API |
| 最低版本 | Android 8.0（API 26） |

# 构建

```bash
cd hibiki/hibiki
flutter pub get
flutter build apk --debug
```

> 首次构建前需打 11 个 pub cache v1 embedding 补丁，详见项目内 `CLAUDE.md`。

# 项目结构

```
hibiki/
├── hibiki/            # Flutter app 主目录
│   ├── lib/src/
│   │   ├── pages/     # 页面（书架、阅读器等）
│   │   ├── media/     # 有声书桥接、字幕解析
│   │   └── dictionary/# 词典查询
│   └── assets/
│       └── ttu-ebook-reader/  # ttu fork 构建产物
├── legacy/            # 遗留参考代码
├── docs/              # 开发文档
└── CLAUDE.md          # 详细开发指南
```

# 开发状态

- **Phase 1** — 精简：剥离 YouTube / VLC / 浏览器 / ChatGPT / 歌词 / Mokuro，保留 Reader + Dictionary + Anki
- **Phase 2** — 有声书同步全链路（字幕解析 → ttu IDB 匹配 → WebView 桥 → 播放 / 制卡）
- **Phase 3** — Material 3 UI 打磨
- **Phase 4** — 对齐 iOS Sasayaki（进行中）

# 致谢

| 项目 | 说明 | 链接 |
|---|---|---|
| jidoujisho | 本项目基于 jidoujisho 重构而来 | [arianneorpilla/jidoujisho](https://github.com/arianneorpilla/jidoujisho) |
| Hoshi Reader | iOS 端日语阅读器，hibiki 的对标目标 | [Manhhao/Hoshi-Reader](https://github.com/Manhhao/Hoshi-Reader) |
| Sasayaki | Hoshi Reader 的有声书同步方案，hibiki 的音频同步参考 | [Sasayaki 文档](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) |
| ッツ Ebook Reader | EPUB 渲染引擎（WebView） | [ttu-ebook-reader](https://github.com/ttu-ttu/ebook-reader) |

# 许可

GNU General Public License 3.0
