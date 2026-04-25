<h3 align="center">hibiki</h3>
<p align="center">Android 日语沉浸式阅读器</p>
<p align="center">EPUB · 词典 · Anki · 有声书同步</p>

<p align="center">
  <a href="#english">English</a> · <a href="#日本語">日本語</a> · <a href="#한국어">한국어</a> · <a href="#español">Español</a> · <a href="#français">Français</a> · <a href="#deutsch">Deutsch</a> · <a href="#português-br">Português</a> · <a href="#русский">Русский</a> · <a href="#tiếng-việt">Tiếng Việt</a> · <a href="#ภาษาไทย">ภาษาไทย</a> · <a href="#bahasa-indonesia">Bahasa Indonesia</a> · <a href="#العربية">العربية</a> · <a href="#繁體中文">繁體中文</a>
</p>

---

## 简介

**hibiki** 是一款面向日语学习者的 Android 阅读应用，基于 [jidoujisho](https://github.com/arianneorpilla/jidoujisho) 重构，功能对标 iOS 端 [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)。

## 功能

### EPUB 阅读
- 内嵌 [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) 渲染 EPUB（WebView）
- 点按即查词，选词即分析
- 自定义字体、主题（明/暗）
- 阅读统计与书签
- 连续滚动 / 分页两种模式

### 词典
- 导入 [Yomitan](https://github.com/yomidevs/yomitan) 格式词典（原 Yomichan）
- 支持音调标注与词频信息
- 多词典并行查询、搜索历史
- Ve 词形还原

### Anki 制卡
- 一键导出至 [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- 自动填充上下文句子
- 支持录音、截图裁剪
- 多导出配置（Profile）、自定义字段映射
- 快速操作（Quick Actions）一步制卡

### 有声书同步（Sasayaki）
- 字幕格式：SRT / LRC / VTT / ASS
- 字幕文本自动对齐 EPUB 正文
- 跟读高亮，音频同步翻页
- 播放控制栏（进度、跳转、倍速）

### 其他
- 14 种界面语言
- 多用户配置（Profile）
- 无痕模式
- 从其他应用分享文本直接查词

## 支持语言

界面支持以下语言：

| 语言 | 代码 |
|---|---|
| English | `en` |
| 简体中文 | `zh-CN` |
| 繁體中文 | `zh-HK` |
| 日本語 | `ja` |
| 한국어 | `ko` |
| Español | `es` |
| Français | `fr` |
| Deutsch | `de` |
| Português (Brasil) | `pt-BR` |
| Русский | `ru` |
| Tiếng Việt | `vi` |
| ภาษาไทย | `th` |
| Bahasa Indonesia | `id` |
| العربية | `ar` |

## 技术栈

| 层 | 技术 |
|---|---|
| 框架 | Flutter 3.41.6 / Dart 3.11.4 |
| 阅读器 | ttu Ebook Reader（WebView，[fork](https://github.com/hdjsadgfwtg/ttu-fork)） |
| 存储 | Isar + Drift (SQLite) + hoshidicts (C++ FFI 词典引擎) |
| NLP | Ve（词形还原） |
| 制卡 | AnkiDroid API |
| 国际化 | Slang |
| 最低版本 | Android 8.0（API 26） |

## 构建

```bash
cd hibiki/hibiki
flutter pub get
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

> **首次构建前需打 pub cache 补丁。** 若 pub cache 被清除或重新 `pub get`，所有补丁需重新应用。详见下方[依赖与补丁](#依赖与补丁)。

## 依赖与补丁

本项目锁定 Flutter 3.41.6，部分上游依赖尚未适配，需手动修补 pub cache 中的源码。

<details>
<summary><b>Flutter API 变更补丁</b></summary>

| 包 | 改动 |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`；`DecoderCallback` → `ImageDecoderCallback`；`hashValues` → `Object.hash`；`instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`；替换已移除的 `imageCache.putIfAbsent` |
| `flutter_blurhash` 0.7.0 | 同上 `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`；`subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | 内部 import 加 `hide CarouselController` 避免命名冲突 |
| `fading_edge_scrollview` 3.0.0 | `PageView.controller` nullable 修复 |

</details>

<details>
<summary><b>v1 Embedding 移除补丁</b></summary>

Flutter 3.41.6 完全移除了 v1 embedding API（`PluginRegistry.Registrar`），以下插件需删除相关引用：

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Gradle / Kotlin 补丁</b></summary>

| 目标 | 改动 |
|---|---|
| `android/build.gradle` afterEvaluate | 子项目强制 `compileSdkVersion 34`；移除 `-Werror` |
| `audio_session` 0.1.14 | 移除 `-Werror`、`-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | Kotlin null 安全修复 |
| `receive_intent` (git) | Kotlin null 安全修复 |

</details>

<details>
<summary><b>Git 依赖</b></summary>

| 包 | 来源 |
|---|---|
| `blurrycontainer` | [arianneorpilla/blurry_container](https://github.com/arianneorpilla/blurry_container/) |
| `filesystem_picker` | [arianneorpilla/filesystem_picker](https://github.com/arianneorpilla/filesystem_picker) |
| `flutter_inappwebview` | [arianneorpilla/flutter_inappwebview](https://github.com/arianneorpilla/flutter_inappwebview) |
| `material_floating_search_bar` | [arianneorpilla/material_floating_search_bar](https://github.com/arianneorpilla/material_floating_search_bar) |
| `ruby_text` | [arianneorpilla/RubyText](https://github.com/arianneorpilla/RubyText) |
| `spaces` | [arianneorpilla/spaces](https://github.com/arianneorpilla/spaces) |
| `ve_dart` | [arianneorpilla/ve_dart](https://github.com/arianneorpilla/ve_dart) |
| `receive_intent` | [arianneorpilla/receive_intent](https://github.com/arianneorpilla/receive_intent) |
| `wakelock` | [diegotori/wakelock](https://github.com/diegotori/wakelock) |

</details>

## 项目结构

```
hibiki/
├── hibiki/                  # Flutter 应用主目录
│   ├── lib/
│   │   ├── i18n/            # 国际化（14 种语言）
│   │   ├── src/
│   │   │   ├── pages/       # 页面（书架、阅读器、词典、设置等）
│   │   │   ├── media/       # 有声书桥接、字幕解析
│   │   │   ├── dictionary/  # 词典查询引擎
│   │   │   ├── models/      # 数据模型与状态管理
│   │   │   └── language/    # 语言抽象层
│   │   └── main.dart
│   ├── assets/
│   │   └── ttu-ebook-reader/ # ttu fork 构建产物
│   └── android/
│       └── app/src/main/cpp/ # hoshidicts C++ 词典引擎
├── docs/                    # 开发文档
├── chisa/                   # jidoujisho 早期版本参考
└── legacy/                  # 遗留参考代码
```

## 致谢

| 项目 | 说明 |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | 本项目基于 jidoujisho 重构，大部分代码与架构源自该项目 |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS 日语阅读器，hibiki 的功能对标目标 |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Hoshi Reader 有声书同步方案，hibiki 音频同步的参考蓝本 |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | EPUB 渲染引擎 |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | ttu 社区维护版（SvelteKit v2），hibiki fork 的上游基准 |
| [Yomitan](https://github.com/yomidevs/yomitan) | 词典格式来源 |

## 许可证

[GNU General Public License v3.0](LICENSE)

---

<!-- Other languages -->

<details>
<summary><h2 id="english">English</h2></summary>

<h3 align="center">hibiki</h3>
<p align="center">Immersive Japanese reader for Android</p>
<p align="center">EPUB · Dictionary · Anki · Audiobook Sync</p>

---

### About

**hibiki** is an Android reading app for Japanese learners, rebuilt from [jidoujisho](https://github.com/arianneorpilla/jidoujisho), aiming to match the feature set of [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) on iOS.

### Features

**EPUB Reading** — Embedded [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) via WebView with tap-to-look-up, custom fonts, light/dark themes, reading statistics, and continuous scroll or paginated mode.

**Dictionary** — Import [Yomitan](https://github.com/yomidevs/yomitan)-format dictionaries with pitch accent and frequency data. Multi-dictionary parallel lookup, search history, and Ve deinflection.

**Anki Flashcards** — One-tap export to [AnkiDroid](https://github.com/ankidroid/Anki-Android) with auto-filled context sentences, audio recording, screenshot cropping, multiple export profiles, and quick actions.

**Audiobook Sync (Sasayaki)** — Align SRT / LRC / VTT / ASS subtitles to EPUB text with follow-along highlighting and synced page turning.

**More** — 14 UI languages, multiple user profiles, incognito mode, share-to-lookup from other apps.

### Requirements

- Android 8.0+ (API 26)

### License

[GNU General Public License v3.0](LICENSE)

</details>

<details>
<summary><h2 id="日本語">日本語</h2></summary>

<h3 align="center">hibiki</h3>
<p align="center">Android 向け日本語イマーシブリーダー</p>
<p align="center">EPUB · 辞書 · Anki · オーディオブック同期</p>

---

### 概要

**hibiki** は日本語学習者のための Android 読書アプリです。[jidoujisho](https://github.com/arianneorpilla/jidoujisho) をベースに再構築し、iOS の [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) と同等の機能を目指しています。

### 機能

**EPUB リーダー** — [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) を WebView で内蔵。タップで辞書引き、カスタムフォント、ライト/ダークテーマ、読書統計、連続スクロールまたはページめくりモード。

**辞書** — [Yomitan](https://github.com/yomidevs/yomitan) 形式の辞書をインポート。アクセント・頻度情報対応、複数辞書の並列検索、検索履歴、Ve 活用形変換。

**Anki カード作成** — [AnkiDroid](https://github.com/ankidroid/Anki-Android) へワンタップエクスポート。文脈文の自動入力、録音、スクリーンショットのトリミング、複数エクスポートプロファイル、クイックアクション。

**オーディオブック同期（Sasayaki）** — SRT / LRC / VTT / ASS 字幕を EPUB テキストに整列し、ハイライト追従と同期ページめくりを実現。

**その他** — 14 の UI 言語、複数ユーザープロファイル、シークレットモード、他のアプリからテキスト共有して検索。

### 動作要件

- Android 8.0 以上（API 26）

### ライセンス

[GNU General Public License v3.0](LICENSE)

</details>

<details>
<summary><h2 id="한국어">한국어</h2></summary>

<h3 align="center">hibiki</h3>
<p align="center">Android용 일본어 몰입형 리더</p>
<p align="center">EPUB · 사전 · Anki · 오디오북 동기화</p>

---

### 소개

**hibiki**는 일본어 학습자를 위한 Android 독서 앱입니다. [jidoujisho](https://github.com/arianneorpilla/jidoujisho)를 기반으로 재구축하였으며, iOS의 [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)와 동일한 기능을 목표로 합니다.

### 기능

**EPUB 리더** — WebView를 통해 [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) 내장. 탭하여 사전 검색, 사용자 정의 글꼴, 라이트/다크 테마, 독서 통계, 연속 스크롤 또는 페이지 넘김 모드.

**사전** — [Yomitan](https://github.com/yomidevs/yomitan) 형식 사전 가져오기. 악센트 및 빈도 정보 지원, 다중 사전 병렬 조회, 검색 기록, Ve 활용형 변환.

**Anki 카드 만들기** — [AnkiDroid](https://github.com/ankidroid/Anki-Android)로 원탭 내보내기. 문맥 문장 자동 입력, 녹음, 스크린샷 자르기, 다중 내보내기 프로필, 퀵 액션.

**오디오북 동기화 (Sasayaki)** — SRT / LRC / VTT / ASS 자막을 EPUB 텍스트에 정렬하여 하이라이트 추적 및 동기화된 페이지 넘김.

**기타** — 14개 UI 언어, 다중 사용자 프로필, 시크릿 모드, 다른 앱에서 텍스트 공유하여 검색.

### 요구 사항

- Android 8.0 이상 (API 26)

### 라이선스

[GNU General Public License v3.0](LICENSE)

</details>

<details>
<summary><h2 id="español">Español</h2></summary>

<h3 align="center">hibiki</h3>
<p align="center">Lector inmersivo de japonés para Android</p>
<p align="center">EPUB · Diccionario · Anki · Sincronización de audiolibros</p>

---

### Acerca de

**hibiki** es una aplicación de lectura en Android para estudiantes de japonés, reconstruida a partir de [jidoujisho](https://github.com/arianneorpilla/jidoujisho), con el objetivo de igualar las funciones de [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) en iOS.

### Características

**Lector EPUB** — [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) integrado vía WebView. Toca para buscar en el diccionario, fuentes personalizadas, temas claro/oscuro, estadísticas de lectura, desplazamiento continuo o modo paginado.

**Diccionario** — Importa diccionarios en formato [Yomitan](https://github.com/yomidevs/yomitan) con acentos tonales y datos de frecuencia. Búsqueda paralela en múltiples diccionarios, historial, desconjugación Ve.

**Tarjetas Anki** — Exportación con un toque a [AnkiDroid](https://github.com/ankidroid/Anki-Android) con oraciones de contexto automáticas, grabación de audio, recorte de capturas, múltiples perfiles de exportación y acciones rápidas.

**Sincronización de audiolibros (Sasayaki)** — Alinea subtítulos SRT / LRC / VTT / ASS con el texto EPUB, con resaltado sincronizado y paso de página automático.

**Más** — 14 idiomas de interfaz, múltiples perfiles de usuario, modo incógnito, compartir texto desde otras apps para buscar.

### Requisitos

- Android 8.0+ (API 26)

### Licencia

[GNU General Public License v3.0](LICENSE)

</details>

<details>
<summary><h2 id="français">Français</h2></summary>

<h3 align="center">hibiki</h3>
<p align="center">Lecteur immersif de japonais pour Android</p>
<p align="center">EPUB · Dictionnaire · Anki · Synchronisation de livres audio</p>

---

### À propos

**hibiki** est une application de lecture Android pour les apprenants du japonais, reconstruite à partir de [jidoujisho](https://github.com/arianneorpilla/jidoujisho), visant à égaler les fonctionnalités de [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) sur iOS.

### Fonctionnalités

**Lecteur EPUB** — [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) intégré via WebView. Appuyez pour chercher dans le dictionnaire, polices personnalisées, thèmes clair/sombre, statistiques de lecture, défilement continu ou mode paginé.

**Dictionnaire** — Importez des dictionnaires au format [Yomitan](https://github.com/yomidevs/yomitan) avec accents tonals et données de fréquence. Recherche parallèle multi-dictionnaires, historique, déconjugaison Ve.

**Cartes Anki** — Export en un clic vers [AnkiDroid](https://github.com/ankidroid/Anki-Android) avec phrases de contexte automatiques, enregistrement audio, recadrage de captures d'écran, profils d'export multiples et actions rapides.

**Synchronisation de livres audio (Sasayaki)** — Alignez les sous-titres SRT / LRC / VTT / ASS avec le texte EPUB, avec surlignage synchronisé et tournage de page automatique.

**Plus** — 14 langues d'interface, profils utilisateur multiples, mode incognito, partage de texte depuis d'autres apps pour recherche.

### Configuration requise

- Android 8.0+ (API 26)

### Licence

[GNU General Public License v3.0](LICENSE)

</details>

<details>
<summary><h2 id="deutsch">Deutsch</h2></summary>

<h3 align="center">hibiki</h3>
<p align="center">Immersiver Japanisch-Reader für Android</p>
<p align="center">EPUB · Wörterbuch · Anki · Hörbuch-Synchronisation</p>

---

### Über

**hibiki** ist eine Android-Lese-App für Japanisch-Lernende, basierend auf [jidoujisho](https://github.com/arianneorpilla/jidoujisho), mit dem Ziel, den Funktionsumfang von [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) auf iOS zu erreichen.

### Funktionen

**EPUB-Reader** — Integrierter [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) via WebView. Tippen zum Nachschlagen, benutzerdefinierte Schriftarten, helles/dunkles Design, Lesestatistiken, Endlos-Scrollen oder Seitenumbruch-Modus.

**Wörterbuch** — Import von [Yomitan](https://github.com/yomidevs/yomitan)-Wörterbüchern mit Tonhöhenakzent und Häufigkeitsdaten. Parallele Suche in mehreren Wörterbüchern, Suchverlauf, Ve-Dekonjugation.

**Anki-Karten** — Ein-Tipp-Export nach [AnkiDroid](https://github.com/ankidroid/Anki-Android) mit automatischen Kontextsätzen, Audioaufnahme, Screenshot-Zuschnitt, mehreren Exportprofilen und Schnellaktionen.

**Hörbuch-Synchronisation (Sasayaki)** — SRT / LRC / VTT / ASS-Untertitel mit dem EPUB-Text abgleichen, mit synchronisierter Hervorhebung und automatischem Seitenwechsel.

**Mehr** — 14 UI-Sprachen, mehrere Benutzerprofile, Inkognito-Modus, Text aus anderen Apps teilen zum Nachschlagen.

### Voraussetzungen

- Android 8.0+ (API 26)

### Lizenz

[GNU General Public License v3.0](LICENSE)

</details>

<details>
<summary><h2 id="português-br">Português (Brasil)</h2></summary>

<h3 align="center">hibiki</h3>
<p align="center">Leitor imersivo de japonês para Android</p>
<p align="center">EPUB · Dicionário · Anki · Sincronização de audiolivros</p>

---

### Sobre

**hibiki** é um aplicativo de leitura Android para estudantes de japonês, reconstruído a partir do [jidoujisho](https://github.com/arianneorpilla/jidoujisho), visando igualar os recursos do [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) no iOS.

### Recursos

**Leitor EPUB** — [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) integrado via WebView. Toque para consultar o dicionário, fontes personalizadas, temas claro/escuro, estatísticas de leitura, rolagem contínua ou modo paginado.

**Dicionário** — Importe dicionários no formato [Yomitan](https://github.com/yomidevs/yomitan) com acento tonal e dados de frequência. Consulta paralela em múltiplos dicionários, histórico de buscas, desconjugação Ve.

**Cartões Anki** — Exportação com um toque para o [AnkiDroid](https://github.com/ankidroid/Anki-Android) com frases de contexto automáticas, gravação de áudio, recorte de capturas de tela, múltiplos perfis de exportação e ações rápidas.

**Sincronização de audiolivros (Sasayaki)** — Alinhe legendas SRT / LRC / VTT / ASS com o texto EPUB, com destaque sincronizado e passagem automática de página.

**Mais** — 14 idiomas de interface, múltiplos perfis de usuário, modo anônimo, compartilhar texto de outros apps para buscar.

### Requisitos

- Android 8.0+ (API 26)

### Licença

[GNU General Public License v3.0](LICENSE)

</details>

<details>
<summary><h2 id="русский">Русский</h2></summary>

<h3 align="center">hibiki</h3>
<p align="center">Иммерсивная читалка японского для Android</p>
<p align="center">EPUB · Словарь · Anki · Синхронизация аудиокниг</p>

---

### О приложении

**hibiki** — приложение для чтения на Android для изучающих японский язык, переработанное на основе [jidoujisho](https://github.com/arianneorpilla/jidoujisho) с целью достичь функциональности [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) на iOS.

### Возможности

**Читалка EPUB** — Встроенный [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) через WebView. Нажатие для поиска в словаре, пользовательские шрифты, светлая/тёмная тема, статистика чтения, непрерывная прокрутка или постраничный режим.

**Словарь** — Импорт словарей формата [Yomitan](https://github.com/yomidevs/yomitan) с тональным ударением и частотностью. Параллельный поиск по нескольким словарям, история поиска, деконъюгация Ve.

**Карточки Anki** — Экспорт одним нажатием в [AnkiDroid](https://github.com/ankidroid/Anki-Android) с автозаполнением контекстных предложений, записью аудио, обрезкой скриншотов, множественными профилями экспорта и быстрыми действиями.

**Синхронизация аудиокниг (Sasayaki)** — Выравнивание субтитров SRT / LRC / VTT / ASS с текстом EPUB, синхронная подсветка и автоматический переход страниц.

**Дополнительно** — 14 языков интерфейса, несколько пользовательских профилей, режим инкогнито, отправка текста из других приложений для поиска.

### Требования

- Android 8.0+ (API 26)

### Лицензия

[GNU General Public License v3.0](LICENSE)

</details>

<details>
<summary><h2 id="tiếng-việt">Tiếng Việt</h2></summary>

<h3 align="center">hibiki</h3>
<p align="center">Ứng dụng đọc tiếng Nhật chuyên sâu cho Android</p>
<p align="center">EPUB · Từ điển · Anki · Đồng bộ sách nói</p>

---

### Giới thiệu

**hibiki** là ứng dụng đọc sách trên Android dành cho người học tiếng Nhật, được xây dựng lại từ [jidoujisho](https://github.com/arianneorpilla/jidoujisho), hướng tới bộ tính năng tương đương [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) trên iOS.

### Tính năng

**Đọc EPUB** — Tích hợp [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) qua WebView. Chạm để tra từ điển, phông chữ tùy chỉnh, giao diện sáng/tối, thống kê đọc, cuộn liên tục hoặc chế độ phân trang.

**Từ điển** — Nhập từ điển định dạng [Yomitan](https://github.com/yomidevs/yomitan) với thanh điệu và dữ liệu tần suất. Tra cứu song song nhiều từ điển, lịch sử tìm kiếm, chuyển đổi dạng Ve.

**Thẻ Anki** — Xuất một chạm sang [AnkiDroid](https://github.com/ankidroid/Anki-Android) với câu ngữ cảnh tự động, ghi âm, cắt ảnh chụp màn hình, nhiều hồ sơ xuất và thao tác nhanh.

**Đồng bộ sách nói (Sasayaki)** — Căn chỉnh phụ đề SRT / LRC / VTT / ASS với văn bản EPUB, đánh dấu đồng bộ và lật trang tự động.

**Khác** — 14 ngôn ngữ giao diện, nhiều hồ sơ người dùng, chế độ ẩn danh, chia sẻ văn bản từ ứng dụng khác để tra cứu.

### Yêu cầu

- Android 8.0+ (API 26)

### Giấy phép

[GNU General Public License v3.0](LICENSE)

</details>

<details>
<summary><h2 id="ภาษาไทย">ภาษาไทย</h2></summary>

<h3 align="center">hibiki</h3>
<p align="center">แอปอ่านภาษาญี่ปุ่นแบบดื่มด่ำสำหรับ Android</p>
<p align="center">EPUB · พจนานุกรม · Anki · ซิงค์หนังสือเสียง</p>

---

### เกี่ยวกับ

**hibiki** เป็นแอปอ่านหนังสือบน Android สำหรับผู้เรียนภาษาญี่ปุ่น พัฒนาใหม่จาก [jidoujisho](https://github.com/arianneorpilla/jidoujisho) โดยมีเป้าหมายให้มีฟีเจอร์เทียบเท่า [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) บน iOS

### คุณสมบัติ

**ตัวอ่าน EPUB** — ฝัง [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) ผ่าน WebView แตะเพื่อค้นหาในพจนานุกรม ฟอนต์กำหนดเอง ธีมสว่าง/มืด สถิติการอ่าน เลื่อนต่อเนื่องหรือแบ่งหน้า

**พจนานุกรม** — นำเข้าพจนานุกรมรูปแบบ [Yomitan](https://github.com/yomidevs/yomitan) พร้อมสำเนียงและข้อมูลความถี่ ค้นหาพร้อมกันหลายพจนานุกรม ประวัติการค้นหา การผันกลับด้วย Ve

**บัตรคำ Anki** — ส่งออกด้วยการแตะครั้งเดียวไปยัง [AnkiDroid](https://github.com/ankidroid/Anki-Android) พร้อมประโยคบริบทอัตโนมัติ บันทึกเสียง ครอปภาพหน้าจอ โปรไฟล์ส่งออกหลายแบบ และการดำเนินการด่วน

**ซิงค์หนังสือเสียง (Sasayaki)** — จับคู่ซับไตเติ้ล SRT / LRC / VTT / ASS กับข้อความ EPUB ไฮไลต์ตามเสียงและเลื่อนหน้าอัตโนมัติ

**อื่นๆ** — 14 ภาษาสำหรับ UI โปรไฟล์ผู้ใช้หลายรายการ โหมดไม่ระบุตัวตน แชร์ข้อความจากแอปอื่นเพื่อค้นหา

### ความต้องการ

- Android 8.0 ขึ้นไป (API 26)

### สัญญาอนุญาต

[GNU General Public License v3.0](LICENSE)

</details>

<details>
<summary><h2 id="bahasa-indonesia">Bahasa Indonesia</h2></summary>

<h3 align="center">hibiki</h3>
<p align="center">Pembaca bahasa Jepang imersif untuk Android</p>
<p align="center">EPUB · Kamus · Anki · Sinkronisasi buku audio</p>

---

### Tentang

**hibiki** adalah aplikasi baca di Android untuk pelajar bahasa Jepang, dibangun ulang dari [jidoujisho](https://github.com/arianneorpilla/jidoujisho), dengan target menyamai fitur [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) di iOS.

### Fitur

**Pembaca EPUB** — [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) terintegrasi via WebView. Ketuk untuk cari di kamus, font kustom, tema terang/gelap, statistik membaca, gulir berkelanjutan atau mode halaman.

**Kamus** — Impor kamus format [Yomitan](https://github.com/yomidevs/yomitan) dengan aksen nada dan data frekuensi. Pencarian paralel multi-kamus, riwayat pencarian, dekonjugasi Ve.

**Kartu Anki** — Ekspor satu ketuk ke [AnkiDroid](https://github.com/ankidroid/Anki-Android) dengan kalimat konteks otomatis, rekaman audio, potong tangkapan layar, beberapa profil ekspor, dan aksi cepat.

**Sinkronisasi buku audio (Sasayaki)** — Selaraskan subtitle SRT / LRC / VTT / ASS dengan teks EPUB, dengan penyorotan sinkron dan pergantian halaman otomatis.

**Lainnya** — 14 bahasa antarmuka, beberapa profil pengguna, mode penyamaran, bagikan teks dari aplikasi lain untuk mencari.

### Persyaratan

- Android 8.0+ (API 26)

### Lisensi

[GNU General Public License v3.0](LICENSE)

</details>

<details>
<summary><h2 id="العربية">العربية</h2></summary>

<h3 align="center">hibiki</h3>
<p align="center">قارئ ياباني غامر لنظام أندرويد</p>
<p align="center">EPUB · قاموس · Anki · مزامنة الكتب الصوتية</p>

---

### حول التطبيق

**hibiki** هو تطبيق قراءة على أندرويد لمتعلمي اللغة اليابانية، أُعيد بناؤه من [jidoujisho](https://github.com/arianneorpilla/jidoujisho)، بهدف مطابقة ميزات [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) على iOS.

### الميزات

**قارئ EPUB** — [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) مدمج عبر WebView. انقر للبحث في القاموس، خطوط مخصصة، سمات فاتحة/داكنة، إحصائيات القراءة، التمرير المستمر أو وضع الصفحات.

**القاموس** — استيراد قواميس بصيغة [Yomitan](https://github.com/yomidevs/yomitan) مع نبرة النطق وبيانات التردد. بحث متوازي في عدة قواميس، سجل البحث، تصريف Ve العكسي.

**بطاقات Anki** — تصدير بنقرة واحدة إلى [AnkiDroid](https://github.com/ankidroid/Anki-Android) مع ملء تلقائي لجمل السياق، تسجيل صوتي، قص لقطات الشاشة، ملفات تصدير متعددة، وإجراءات سريعة.

**مزامنة الكتب الصوتية (Sasayaki)** — محاذاة ترجمات SRT / LRC / VTT / ASS مع نص EPUB، مع تمييز متزامن وتقليب الصفحات تلقائياً.

**المزيد** — 14 لغة للواجهة، ملفات تعريف مستخدمين متعددة، وضع التصفح المتخفي، مشاركة النص من تطبيقات أخرى للبحث.

### المتطلبات

- أندرويد 8.0 فما فوق (API 26)

### الرخصة

[GNU General Public License v3.0](LICENSE)

</details>

<details>
<summary><h2 id="繁體中文">繁體中文</h2></summary>

<h3 align="center">hibiki</h3>
<p align="center">Android 日語沉浸式閱讀器</p>
<p align="center">EPUB · 詞典 · Anki · 有聲書同步</p>

---

### 簡介

**hibiki** 是一款面向日語學習者的 Android 閱讀應用，基於 [jidoujisho](https://github.com/arianneorpilla/jidoujisho) 重構，功能對標 iOS 端 [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)。

### 功能

**EPUB 閱讀** — 內嵌 [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) 透過 WebView 渲染。點按即查詞、自訂字型、明/暗主題、閱讀統計、連續捲動或分頁模式。

**詞典** — 匯入 [Yomitan](https://github.com/yomidevs/yomitan) 格式詞典，支援音調標注與詞頻資訊。多詞典並行查詢、搜尋歷史、Ve 詞形還原。

**Anki 製卡** — 一鍵匯出至 [AnkiDroid](https://github.com/ankidroid/Anki-Android)，自動填充上下文句子、錄音、截圖裁剪、多匯出設定檔與快速操作。

**有聲書同步（Sasayaki）** — SRT / LRC / VTT / ASS 字幕對齊 EPUB 正文，跟讀高亮與音訊同步翻頁。

**其他** — 14 種介面語言、多使用者設定檔、無痕模式、從其他應用分享文字直接查詞。

### 系統需求

- Android 8.0 以上（API 26）

### 授權條款

[GNU General Public License v3.0](LICENSE)

</details>
