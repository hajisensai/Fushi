<div align="center">

# hibiki

<img src="../static-assets/hibiki-logo.png" alt="hibiki ロゴ" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | **日本語** | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

hibiki は Android と Windows 向けの没入型語学学習ツールです。EPUB 読書、オーディオブック同期、動画字幕の単語検索、ワンタップでの Anki カード作成を一つにまとめ、あらゆるインプットが自然に復習可能な語彙になります。

<table>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-bookshelf-en.png" alt="本棚" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-library-en.png" alt="動画ライブラリ" width="100%"></td>
  </tr>
  <tr>
    <td colspan="2"><img src="../static-assets/screenshots/hibiki-readme-reader-vertical-lookup.png" alt="デスクトップでの縦書き読書と検索ポップアップ" width="100%"></td>
  </tr>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-nested.png" alt="動画の単語検索（ネストポップアップ）" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-subtitle.png" alt="動画の単語検索（字幕リスト）" width="100%"></td>
  </tr>
</table>

</div>

## 機能

### 本棚

- EPUB を個別、一括、またはフォルダ単位で再帰的にインポートし、本棚上で読書進捗を確認できます。
- カスタム本棚、タグフィルタ、ドラッグでの並べ替えで書籍を整理できます。
- ファイルをドラッグ＆ドロップして書籍・字幕・動画をインポートできます（デスクトップ）。
- インポート時に同名の字幕／音声ファイルを自動的に関連付けます。

### 読書

- 縦書き・横書きのレイアウトで読書でき、ページめくりモードと連続スクロールモードを切り替えられます。
- テーマ（ライト／ダーク／純黒／カスタム）、フォント、段落間隔、リーダーコントロールをカスタマイズできます。
- ふりがな（Furigana）の注釈を表示します。
- UI スケールを調整でき、ボトムバーのコントロールもスケールに追従します。
- マルチユーザープロファイル（Profile）に対応し、書籍ごとに自動で切り替えます。

### 単語検索

- [Yomitan](https://github.com/yomidevs/yomitan)（旧 Yomichan）、ABBYY Lingvo（DSL）、MDict（MDX）、Migaku の辞書をインポートできます。
- リーダーでテキストをタップして単語を検索したり、辞書ページで検索したり、他アプリからテキストを共有して検索できます。
- **Yomitan のすべての変換言語**をカバーする活用復元と、検索前のテキスト正規化（大文字小文字／発音区別符号／アラビア語のハラカート）を備え、コードポイント駆動で言語の切り替えは不要です。
- 語釈内の単語をタップして再帰的に検索できます（ネストポップアップ）。
- 複数辞書の並列クエリ、サブソースの優先順位設定と切り替え、ピッチアクセントと頻度の注釈に対応します。
- オンラインおよびローカルの単語音声を再生できます。
- カスタム CSS を注入できます。

### ハイライトと統計

- 読書中に 5 色のハイライトを追加でき、いつでも任意のハイライトへジャンプできます。
- 読書統計：読んだ文字数、所要時間、読書速度を読書中にリアルタイムで表示します。
- 動画統計：視聴時間、作成したカード数、お気に入り数を表示します。

### Anki カード作成

- [AnkiDroid](https://github.com/ankidroid/Anki-Android) または AnkiConnect でカードを作成できます。
- [Lapis](https://github.com/donkuri/lapis) ノートタイプを内蔵（vendored 1.7.0）し、アプリ内でワンタップでカードテンプレートとデッキを作成できます。
- 文脈の例文を自動入力し、音声録音とスクリーンショットの切り抜きに対応します。
- 複数のエクスポートプロファイル（Profile）とカスタムフィールドマッピングに対応します。
- 単語をお気に入りに追加でき、作成したカードとお気に入りは統計に集計されます。

### オーディオブック同期（Sasayaki）

- SRT / LRC / VTT / ASS 字幕に対応し、字幕テキストを EPUB 本文に自動で整列させます。
- 再生中の文の追従ハイライトと自動ページめくりに対応します。
- 再生速度、シーク操作、システムメディアコントロールに対応します。
- 「この文から再生」で章をまたいでシームレスに継続再生できます。

### 動画字幕の単語検索

- [media_kit](https://github.com/media-kit/media-kit)（libmpv コア）ベースの動画プレーヤーを内蔵しています。
- 内蔵字幕（テキスト＋グラフィックトラック）と外部字幕、.m3u8 プレイリストのインポートに対応します。
- 再生中に字幕から直接単語を検索してカードを作成できます。
- 動画ライブラリの管理、タグフィルタ、シリーズのグループ化、一括操作に対応します。

### データ同期

- 7 つの同期バックエンド：Google Drive、OneDrive、Dropbox、WebDAV、FTP、SFTP、Hibiki P2P。
- 読書進捗、統計、書籍を同期します。

### その他

- **17 のインターフェース言語**を備え、すべてのプラットフォームで完全にローカライズされています。
- 他アプリからテキストを共有して直接単語を検索できます。

## プラットフォーム対応

| プラットフォーム | 状態 | レンダリング／UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material |

> 最小要件は Android 7.0（API 24）です。辞書検索で利用できる言語は、インポートした辞書と Yomitan の変換テーブルによって決まり、インターフェース言語とは独立しています。

### インターフェース言語（17）

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## インストールとビルド

ワンコマンドで準備（`flutter pub get` ＋ パッチ適用）し、ビルドします。

```bash
# リポジトリのルートから
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd hibiki
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Windows デスクトップ
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` は `flutter pub get` と `ci/apply-patches.sh` を一つのコマンドにまとめます。本プロジェクトは Flutter 3.44.0（Dart SDK `>=3.5.0 <4.0.0`）に固定されています。一部の上流依存は `third_party/` に vendored されているか、`ci/apply-patches.sh` によってパッチが当てられます。詳細は [docs/agent/build.md](../agent/build.md) を参照してください。

<details>
<summary><b>技術スタック</b></summary>

| レイヤー | 技術 |
|---|---|
| フレームワーク | Flutter 3.44.0（Dart SDK `>=3.5.0 <4.0.0`） |
| プラットフォーム | Android / Windows（Material Design 3） |
| リーダー | WebView ページングエンジン（Hoshi Reader 系統から派生） |
| 動画 | media_kit（libmpv コア） |
| ストレージ | Drift（SQLite, WAL）＋ hoshidicts（C++ FFI 辞書エンジン） |
| NLP | Yomitan 変換テーブル（多言語の見出し語化）＋ kana_kit（かな変換）；トークン化は hoshidicts FFI 経由 |
| カード作成 | AnkiDroid API ＋ AnkiConnect |
| i18n | Slang（17 言語） |

</details>

<details>
<summary><b>プロジェクト構成</b></summary>

```
hibiki/                      # Repository root (Melos workspace: hibiki_workspace)
├── hibiki/                  # Flutter アプリのメインディレクトリ
│   ├── lib/
│   │   ├── i18n/            # 国際化（17 言語、Slang）
│   │   ├── src/
│   │   │   ├── pages/       # ページ（本棚、リーダー、辞書、設定など）
│   │   │   ├── reader/      # リーダー WebView の JS/CSS スクリプト
│   │   │   ├── media/       # オーディオブック、字幕解析、リーダーソース
│   │   │   └── models/      # データモデルと状態管理（AppModel）
│   │   └── main.dart
│   └── android/             # Android プロジェクト（manifest、ネイティブ hoshidicts）
├── packages/                # 内部パッケージ ＋ flutter_inappwebview_windows (fork) ＋ gamepads_android_stub
├── native/                  # hoshidicts C++ 辞書エンジン（FFI）
├── third_party/             # vendored されたパッチ済みパッケージ（dependency_overrides）
├── ci/                      # ビルドパッチと統合テストスクリプト
├── tool/                    # bootstrap / i18n_sync などのスクリプト
└── docs/                    # 開発ドキュメント（docs/agent/ 運用マニュアルを含む）
```

</details>

## プライバシーとデータ

hibiki は、インポートした書籍、辞書、フォント、オーディオブックのデータ、動画、読書進捗、ハイライト、統計、設定をアプリのローカルストレージに保存します。

クラウド同期（Google Drive / OneDrive / Dropbox）はユーザーが設定した OAuth 認証情報を使用します。WebDAV / FTP / SFTP はユーザーが提供するサーバーアドレスと認証情報を使用します。Hibiki P2P はユーザーが設定したアドレスで直接接続します。Anki カード作成は AnkiDroid または設定された AnkiConnect アドレスと通信します。

## 謝辞

hibiki は以下のプロジェクトとエコシステムを基盤としています。

| プロジェクト | 説明 |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | 日本語没入型学習ツール |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS 向け日本語リーダー；リーダーページングエンジンの参考 |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android ネイティブの日本語リーダー |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ 辞書エンジン |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | オーディオブック同期ソリューション |
| [Yomitan](https://github.com/yomidevs/yomitan) | 辞書フォーマット、変換テーブル、検索体験の参考 |
| [Lapis](https://github.com/donkuri/lapis) | Anki ノートタイプ |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Android カード作成の統合 |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | ローカル音声と AnkiDroid 連携の参考 |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | リーダー、統計、同期の互換性の参考 |
| [media_kit](https://github.com/media-kit/media-kit) | Flutter 動画再生フレームワーク（libmpv コア） |

## ライセンス

GNU General Public License v3.0 の下で配布されます。詳細は [LICENSE](../../LICENSE) を参照してください。

<div align="center">

<br>

[简体中文](../../README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | **日本語** | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
