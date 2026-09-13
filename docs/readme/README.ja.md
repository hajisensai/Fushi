<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="Fushi ロゴ" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | **日本語** | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![最新版をダウンロード](https://img.shields.io/badge/%E2%AC%87%20%E6%9C%80%E6%96%B0%E7%89%88%E3%82%92%E3%83%80%E3%82%A6%E3%83%B3%E3%83%AD%E3%83%BC%E3%83%89-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Discord に参加](https://img.shields.io/badge/Discord%20%E3%81%AB%E5%8F%82%E5%8A%A0-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## プラットフォーム対応

| プラットフォーム | 状態 | レンダリング／UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material Design 3 |
| macOS | ✅ | Material Design 3 |
| Linux | 🔧 (build from source) | Material Design 3 |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | Material Design 3 |

> 最小要件は Android 7.0（API 24）です。辞書検索で利用できる言語は、インポートした辞書と Yomitan の変換テーブルによって決まり、インターフェース言語とは独立しています。iOS 版は TestFlight で配布しています。App Store の審査ガイドラインが認めていない発見・ダウンロード機能は含まれず、更新も他のプラットフォームより数日遅れます。

### インターフェース言語（17）

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## インストールとビルド

ワンコマンドで準備（`flutter pub get` ＋ パッチ適用）し、ビルドします。

```bash
# リポジトリのルートから
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
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
| プラットフォーム | Android / Windows / macOS / iOS（Material Design 3） |
| リーダー | WebView ページングエンジン（Hoshi Reader 系統から派生） |
| 動画 | media_kit（libmpv コア） |
| ストレージ | Drift（SQLite, WAL）＋ fushidicts（C++ FFI 辞書エンジン） |
| NLP | Yomitan 変換テーブル（多言語の見出し語化）＋ kana_kit（かな変換）；トークン化は fushidicts FFI 経由 |
| カード作成 | AnkiDroid API ＋ AnkiConnect |
| i18n | Slang（17 言語） |

</details>

<details>
<summary><b>プロジェクト構成</b></summary>

```
Fushi/                      # Repository root (Melos workspace: fushi_workspace)
├── fushi/                  # Flutter アプリのメインディレクトリ
│   ├── lib/
│   │   ├── i18n/            # 国際化（17 言語、Slang）
│   │   ├── src/
│   │   │   ├── pages/       # ページ（本棚、リーダー、辞書、設定など）
│   │   │   ├── reader/      # リーダー WebView の JS/CSS スクリプト
│   │   │   ├── media/       # オーディオブック、字幕解析、リーダーソース
│   │   │   └── models/      # データモデルと状態管理（AppModel）
│   │   └── main.dart
│   └── android/             # Android プロジェクト（manifest、ネイティブ fushidicts）
├── packages/                # 内部パッケージ ＋ flutter_inappwebview_windows (fork) ＋ gamepads_android_stub
├── native/                  # fushidicts C++ 辞書エンジン（FFI）
├── third_party/             # vendored されたパッチ済みパッケージ（dependency_overrides）
├── ci/                      # ビルドパッチと統合テストスクリプト
├── tool/                    # bootstrap / i18n_sync などのスクリプト
└── docs/                    # 開発ドキュメント（docs/agent/ 運用マニュアルを含む）
```

</details>

## プライバシーとデータ

Fushi は、インポートした書籍、辞書、フォント、オーディオブックのデータ、動画、読書進捗、ハイライト、統計、設定をアプリのローカルストレージに保存します。

クラウド同期（Google Drive / OneDrive / Dropbox）はユーザーが設定した OAuth 認証情報を使用します。WebDAV / FTP / SFTP はユーザーが提供するサーバーアドレスと認証情報を使用します。Fushi Interconnect はユーザーが設定したアドレスで直接接続します。Anki カード作成は AnkiDroid または設定された AnkiConnect アドレスと通信します。

## 謝辞

Fushi は以下のプロジェクトとエコシステムを基盤としています。

### 学習ツールと先行事例

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
| [Niratan](https://github.com/W1ght/Niratan) | macOS 向け没入型言語学習スイート |

### エンジンとネイティブコンポーネント

| プロジェクト | 説明 |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | ギャルゲーのテキストフックエンジン（vendored DLL、インジェクターが読み込み） |
| [MinHook](https://github.com/TsudaKageyu/minhook) | ギャルゲーインジェクターが使うインラインフックライブラリ |
| [libtorrent](https://github.com/arvidn/libtorrent) | 内蔵 torrent ダウンロードエンジン |
| [mpv](https://github.com/mpv-player/mpv) | media_kit の基盤となる libmpv 再生コア |
| [FFmpeg](https://ffmpeg.org) | メディア解析、切り出し、音声抽出 |
| [libplacebo](https://github.com/haasn/libplacebo) | GPU 映像シェーダーと HDR トーンマッピング |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | EPUB リーダーを描画する WebView エンジン |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | 音声認識と OCR の端末内推論 |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | 辞書エンジンの依存ライブラリ |

### 端末内モデル

| プロジェクト | 説明 |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Zipformer 音声認識モデルパッケージと VAD ビルド |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | 日本語音声認識モデル |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | 多言語 CTC 音声認識モデル |
| [Silero VAD](https://github.com/snakers4/silero-vad) | 音声区間検出モデル |
| [manga-ocr](https://github.com/kha-white/manga-ocr) / [manga-ocr-onnx](https://huggingface.co/mayocream/manga-ocr-onnx) | マンガ OCR モデル |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | マンガのテキストと吹き出し検出モデル |

### コンテンツソースと連携

| プロジェクト | 説明 |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | マンガソース拡張のエコシステム |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | デスクトップ向けマンガ拡張ランタイム |
| [aidoku-rs](https://github.com/Aidoku/aidoku-rs) | マンガソースランタイムの ABI |
| [asbplayer](https://github.com/asbplayer/asbplayer) | ブラウザ拡張のストリーミング字幕ブリッジの参考 |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | アニメ識別とスクレイピング設計の参考 |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | ギャルゲーライブラリの情報設計の参考 |
| [AniDB](https://anidb.net) | アニメ・エピソード・ファイルの同定 |
| [TMDB](https://www.themoviedb.org) | 補助的なメタデータと画像 |
| [Jimaku](https://jimaku.cc) | 日本語字幕ソース |
| [OpenSubtitles](https://www.opensubtitles.com) | 字幕ソース |

> このアプリケーションはTMDBおよびTMDB APIを使用していますが、TMDBによる推奨、認証、その他の承認を受けたものではありません。

## ライセンス

GNU General Public License v3.0 の下で配布されます。詳細は [LICENSE](../../LICENSE) を参照してください。

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | **日本語** | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
