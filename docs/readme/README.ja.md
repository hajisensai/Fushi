<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">Android 向け日本語イマーシブリーダー</p>
<p align="center">EPUB · 辞書 · Anki · オーディオブック同期</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <b>日本語</b> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## 概要

**hibiki** は日本語学習者のための Android 読書アプリです。

## 機能

### EPUB リーダー
- WebView で EPUB を描画（[Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) 由来のページングエンジン）
- タップで辞書引き、選択で解析
- カスタムフォント、テーマ（ライト／ダーク）
- 読書統計とブックマーク
- 連続スクロール／ページ送りの 2 モード

### 辞書
- [Yomitan](https://github.com/yomidevs/yomitan) 形式の辞書をインポート（旧 Yomichan）
- アクセント表示と語彙頻度情報に対応
- 複数辞書の並列検索、検索履歴
- Ve による活用形の原形復元

### Anki カード作成
- [AnkiDroid](https://github.com/ankidroid/Anki-Android) へワンタップエクスポート
- 文脈文の自動入力
- 録音・スクリーンショットのトリミングに対応
- 複数エクスポートプロファイル、カスタムフィールドマッピング
- クイックアクションでワンステップ作成

### オーディオブック同期（Sasayaki）
- 字幕形式：SRT / LRC / VTT / ASS
- 字幕テキストを EPUB 本文に自動整列
- 追従ハイライト、音声同期ページ送り
- 再生コントロールバー（進捗、シーク、倍速）

### その他
- 17 種類のインターフェース言語
- 複数ユーザープロファイル
- シークレットモード
- 他のアプリからテキストを共有して直接辞書引き

## 対応言語

インターフェースは以下の言語をサポートしています：

| 言語 | コード |
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
| Italiano | `it` |
| Nederlands | `nl` |
| Türkçe | `tr` |
| العربية | `ar` |

## 技術スタック

| レイヤー | 技術 |
|---|---|
| フレームワーク | Flutter 3.44.0（Dart SDK `>=3.5.0 <4.0.0`） |
| プラットフォーム | Android / iOS / macOS / Windows / Linux（Material 3 + Cupertino アダプティブ） |
| リーダー | WebView ページングエンジン（[Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) 由来） |
| ストレージ | Drift (SQLite、WAL) + hoshidicts (C++ FFI 辞書エンジン) |
| NLP | Ve（活用形の原形復元） |
| カード作成 | AnkiDroid API |
| 国際化 | Slang（17 言語） |
| 最低バージョン | Android 7.0（API 24） |

## ビルド

ワンコマンド準備（`flutter pub get` + パッチ適用）の後、ビルドします：

```bash
# リポジトリのルートで
bash tool/bootstrap.sh          # Windows PowerShell：.\tool\bootstrap.ps1
                                # または（Linux/macOS）：dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` は 2 つの処理を 1 コマンドにまとめます：①`flutter pub get`；②`ci/apply-patches.sh` の実行。`melos bootstrap` も post hook で同じ処理を行います（Windows では melos に CJK エンコーディングのバグがあるため `tool/bootstrap.ps1` を使用してください）。

> **パッチの説明：** `ci/apply-patches.sh` は `ci/patches/` 配下の変更を実際の pub cache に上書きします。pub cache をクリアするか `flutter pub get` を再実行するたびに再実行が必要です（bootstrap はこのステップを含みます）。スクリプトはパッチ対象が見つからない場合、成功したふりをせずスキップして警告します。

## 依存関係とパッチ

本プロジェクトは Flutter 3.44.0 に固定されており、一部の上流依存パッケージはまだ未対応です。パッチは 2 つの仕組みに分かれます：① ビルド入力として必要でマシン間で一貫して再現すべきパッケージは `third_party/` に直接 vendor し `dependency_overrides` で指定します（`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`、pub-cache パッチは**不要**）；② その他のパッケージは `ci/apply-patches.sh` が pub cache のソースをパッチします。仕組みの詳細は [docs/agent/build.md](../agent/build.md) を参照してください。下の折りたたみ表は変更内容で分類した歴史的なリストで、仕組み①と重複するパッケージは vendored 版が優先されます。

<details>
<summary><b>Flutter API 変更パッチ</b></summary>

| パッケージ | 変更内容 |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`；`DecoderCallback` → `ImageDecoderCallback`；`hashValues` → `Object.hash`；`instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`；削除された `imageCache.putIfAbsent` を置換 |
| `flutter_blurhash` 0.7.0 | 同上の `loadImage` / `hashValues` / `ImmutableBuffer` 変更 |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`；`subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | 内部 import に `hide CarouselController` を追加し命名衝突を回避 |
| `fading_edge_scrollview` 3.0.0 | `PageView.controller` の nullable 修正 |

</details>

<details>
<summary><b>v1 Embedding 削除パッチ</b></summary>

Flutter 3.44.0 では v1 embedding API（`PluginRegistry.Registrar`）が完全に削除されました。以下のプラグインから関連する参照を削除する必要があります：

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Gradle / Kotlin パッチ</b></summary>

| 対象 | 変更内容 |
|---|---|
| `android/build.gradle` afterEvaluate | サブプロジェクトに `compileSdk` を強制（デフォルト 36、一部 34）；`-Werror` を削除 |
| `audio_session` 0.1.14 | `-Werror`、`-Xlint:deprecation` を削除 |
| `package_info_plus` 4.0.2 | Kotlin null 安全の修正 |
| `receive_intent` (git) | Kotlin null 安全の修正 |

</details>

<details>
<summary><b>Git 依存パッケージ</b></summary>

| パッケージ | ソース |
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

## プロジェクト構成

```
hibiki/                      # リポジトリのルート（Melos workspace: hibiki_workspace）
├── hibiki/                  # Flutter アプリのメインディレクトリ
│   ├── lib/
│   │   ├── i18n/            # 国際化（17 言語、Slang）
│   │   ├── src/
│   │   │   ├── pages/       # ページ（本棚、リーダー、辞書、設定など）
│   │   │   ├── reader/      # リーダー WebView の JS/CSS スクリプト
│   │   │   ├── media/       # オーディオブック、字幕パース、reader source
│   │   │   └── models/      # データモデルと状態管理（AppModel）
│   │   └── main.dart
│   └── android/             # Android プロジェクト（manifest、native hoshidicts）
├── packages/                # 内部パッケージ + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── third_party/             # vendored パッチパッケージ（dependency_overrides が指定）
├── ci/                      # ビルドパッチと統合テストスクリプト
├── tool/                    # bootstrap / i18n_sync などのスクリプト
└── docs/                    # 開発ドキュメント（docs/agent/ エージェント操作マニュアルを含む）
```

## 謝辞

| プロジェクト | 説明 |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | 日本語イマーシブ学習ツール |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android 日本語リーダー |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ 辞書エンジン |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS 日本語リーダー |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | オーディオブック同期ソリューション |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | EPUB レンダリングエンジン |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | ttu コミュニティメンテナンス版（SvelteKit v2）、hibiki fork の上流ベース |
| [Yomitan](https://github.com/yomidevs/yomitan) | 辞書フォーマットのソース |

## ライセンス

[GNU General Public License v3.0](../../LICENSE)
