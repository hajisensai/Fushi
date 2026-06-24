<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center"><b>一冊の本を読み、知らない言葉をすべて自分のものにする。</b></p>
<p align="center">マルチプラットフォーム・多言語のイマーシブリーダー —— EPUB 読書 · タップで辞書引き · Anki カード作成 · オーディオブック同期 · 動画字幕の辞書引き</p>

<p align="center">
  <img src="https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white" alt="Android">
  <img src="https://img.shields.io/badge/iOS-000000?logo=apple&logoColor=white" alt="iOS">
  <img src="https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white" alt="macOS">
  <img src="https://img.shields.io/badge/Windows-0078D6?logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/Linux-FCC624?logo=linux&logoColor=black" alt="Linux">
  &nbsp;·&nbsp;
  <img src="https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/license-GPLv3-blue" alt="GPLv3">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>📖 プロジェクトホームページ (GitHub Pages)</b></a>
</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <b>日本語</b> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## 概要

**hibiki** はマルチプラットフォームのイマーシブ言語学習リーダーです。EPUB 本文の中で**タップして辞書引き、選択して解析**し、知らない言葉をワンタップで Anki カードにできます。オーディオブックの音声を本文と一文ずつ同期してハイライトし、さらには動画の字幕からそのまま辞書引き・カード作成も可能です。一つのツールで「読む・聴く・観る」の 3 つのイマーシブな入力をカバーします。

辞書引きは [Yomitan](https://github.com/yomidevs/yomitan) の**すべての変換言語**（活用解除 + 辞書引き前のテキスト正規化）に対応し、インターフェースは **17 言語**にローカライズされ、**Android / iOS / macOS / Windows / Linux** の 5 つのプラットフォームに対応します。

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-home.png" alt="本棚" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-dictionaries.png" alt="辞書引き" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-settings.png" alt="設定とテーマ" width="300">
</p>
<p align="center"><sub>本棚 · 辞書引き · 設定とテーマ</sub></p>

---

## 主な機能

### 📖 EPUB 読書、タップで辞書引き

WebView で描画される EPUB リーダー（[Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) 由来のページングエンジン）。任意の単語をタップすると即座に辞書引き、選択範囲をその場で解析します。連続スクロールとページ送りの 2 モード、カスタムフォントとテーマ（ライト / ダーク / 純黒 / カスタム）、ふりがな、読書統計、ブックマークまで一通り揃っています。

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-reader.png" alt="縦書き読書 · ふりがな · オーディオブック同期" width="300">
</p>
<p align="center"><sub>縦書き本文 · ふりがな · 選択ハイライト · 下部のオーディオブック同期コントロールバー</sub></p>

### 🔍 タップで辞書引き、Yomitan のすべての変換言語に対応

**Yomitan**（旧 Yomichan）/ **ABBYY Lingvo (DSL)** / **MDict (MDX)** / **Migaku** など複数形式の辞書をインポートできます。多言語の活用形復元（Yomitan 変換表）+ 辞書引き前のテキスト正規化（大文字小文字 / ダイアクリティカルマーク / アラビア語の harakat）に対応し、コードポイント駆動で言語の切り替えは不要です。複数辞書の並列検索、サブソースの優先順位と有効・無効の切り替え、アクセント表記、語彙頻度——すべて一つのポップアップで完結します。

### 🎴 ワンタップ Anki カード作成

知らない言葉を見つけたら、[AnkiDroid](https://github.com/ankidroid/Anki-Android) と AnkiConnect へ一手でエクスポート。内蔵の [Lapis](https://github.com/donkuri/lapis) ノートタイプ schema（vendored 1.7.0）で、アプリ内から直接カードテンプレートとデッキを作成できます。文脈文を自動入力し、録音とスクリーンショットのトリミング、複数のエクスポートプロファイル（Profile）、カスタムフィールドマッピング、クイックアクションによるワンステップ作成に対応します。

### 🎧 オーディオブック同期（Sasayaki）

SRT / LRC / VTT / ASS 字幕に対応し、字幕テキストを EPUB 本文に自動整列します。再生時には**追従ハイライトと音声同期ページ送り**で、聴きながら本文が一文ずつ点灯します。再生コントロールバー（進捗、シーク、倍速）も備え——本ページ上部の読書スクリーンショット下部のコントロールバーがまさにこの機能です。

### 🎬 動画字幕の辞書引き

media_kit / libmpv ベースの動画プレーヤーを内蔵し、内蔵字幕・外部字幕の両方に対応します。動画再生中に**字幕から直接辞書引き・カード作成**ができ、映像作品の素材もイマーシブな入力に取り込めます。視聴時間とカード作成数の統計も記録します。

<!-- TODO-782: 待补视频播放器截图 -->
<p align="center"><sub>📹 動画プレーヤーのスクリーンショットは後日追加予定 —— 実機 / フォアグラウンドでの取得が必要です（動画画面 + 字幕バー + 辞書引きポップアップ、下記の説明を参照）。</sub></p>

### 🔗 その他

- **17 種類のインターフェース言語**、全プラットフォームでローカライズ
- **Hibiki 相互接続**：端末間で書籍 / 辞書 / オーディオブック / 読書進捗を同期
- **複数ユーザープロファイル（Profile）**、本ごとに自動切り替え
- **シークレットモード**；他のアプリから**テキストを共有してそのまま辞書引き**

---

## 対応プラットフォーム

| プラットフォーム | 状態 | 描画 / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| iOS | ✅ | Cupertino |
| Windows | ✅ | Material（fork した `flutter_inappwebview_windows` で EPUB を描画） |
| macOS | ✅ | Material |
| Linux | ✅ | Material |

> 最低 Android 7.0（API 24）。辞書引きの言語はインポートした辞書と Yomitan 変換表によって決まり、インターフェース言語とは独立しています。

### インターフェース言語（17 種類）

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

---

## インストールとビルド

ワンコマンド準備（`flutter pub get` + パッチ適用）の後、ビルドします：

```bash
# 在仓库根目录
bash tool/bootstrap.sh          # Windows PowerShell：.\tool\bootstrap.ps1
                                # 或（Linux/macOS）：dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` は ①`flutter pub get` と ②`ci/apply-patches.sh` を 1 コマンドにまとめます。本プロジェクトは Flutter 3.44.0（Dart SDK `>=3.5.0 <4.0.0`）に固定されており、一部の上流依存は `third_party/` に vendor されるか `ci/apply-patches.sh` でパッチされます——仕組みの詳細、5 プラットフォームのビルド、依存とパッチの一覧は [docs/agent/build.md](../agent/build.md) を参照してください。

<details>
<summary><b>技術スタック一覧</b></summary>

| レイヤー | 技術 |
|---|---|
| フレームワーク | Flutter 3.44.0（Dart SDK `>=3.5.0 <4.0.0`） |
| プラットフォーム | Android / iOS / macOS / Windows / Linux（Material 3 + Cupertino アダプティブ） |
| リーダー | WebView ページングエンジン（[Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) 由来） |
| 動画 | media_kit / libmpv |
| ストレージ | Drift（SQLite、WAL）+ hoshidicts（C++ FFI 辞書エンジン） |
| NLP | Yomitan 変換表（多言語の活用形復元）+ kana_kit（かな変換）；分かち書きは hoshidicts FFI |
| カード作成 | AnkiDroid API + AnkiConnect |
| 国際化 | Slang（17 言語） |

</details>

<details>
<summary><b>プロジェクト構成</b></summary>

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
├── native/                  # hoshidicts C++ 辞書エンジン（FFI）
├── third_party/             # vendored パッチパッケージ（dependency_overrides が指定）
├── ci/                      # ビルドパッチと統合テストスクリプト
├── tool/                    # bootstrap / i18n_sync などのスクリプト
└── docs/                    # 開発ドキュメント（docs/agent/ エージェント操作マニュアルを含む）
```

</details>

---

## 謝辞

| プロジェクト | 説明 |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | 日本語イマーシブ学習ツール |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android 日本語リーダー |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ 辞書エンジン |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS 日本語リーダー |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | オーディオブック同期ソリューション |
| [Yomitan](https://github.com/yomidevs/yomitan) | 辞書フォーマットと変換表のソース |
| [Lapis](https://github.com/donkuri/lapis) | Anki ノートタイプ |

## ライセンス

[GNU General Public License v3.0](../../LICENSE)

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <b>日本語</b> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>
