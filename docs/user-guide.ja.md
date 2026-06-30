# hibiki ユーザーガイド

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | **日本語** | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> 簡体字中国語版のガイドは Feishu でホストされています（上記リンク）。英語版は [GitHub 版](https://github.com/hajisensai/hibiki/blob/main/docs/user-guide.md) でも利用できます。

## はじめに

これは Android / Windows（iOS / macOS は計画中）向けの無料ソフトウェアです——小説の読書、オーディオブックの再生、動画の再生、辞書検索を一つにまとめた、画期的なマルチプラットフォームのオープンソースアプリです。

### プロジェクト URL

https://github.com/hajisensai/hibiki

活発に開発中です——あなたのフィードバックには迅速に対応します。バグ報告や機能リクエストを歓迎します。Hibiki が役に立つと感じたら、ほかの人にシェアしたり、リポジトリに ⭐ を付けていただけると嬉しいです。

### ダウンロード

https://github.com/hajisensai/hibiki/releases/latest

Android：**arm64** を選んでください。Windows：**.exe** ファイルを選んでください。

## 設定チュートリアル

### 1. 推奨辞書とローカル音声をインポートする（任意）

[OneDrive](https://zfile.kanochi.cn/dl/Public/%E6%9D%82%E9%A1%B9/hibiki-backup-2026-06-29.hibiki.zip) / [Google Drive](https://drive.google.com/file/d/1JYzv6dXB5sDPQBxttFLJzlmN3XTTo79S/view?usp=sharing)

アプリ内で：設定 -> 同期とバックアップ -> **バックアップをインポート** をタップします。

**注意：バックアップをインポートするとローカルデータが消去されます。このフローは今後のアップデートで改善される予定です。**

![バックアップのインポート画面](static-assets/user-guide/import-backup.png)

### 2. Anki 公式サイトから Anki をダウンロードして設定する

Anki——「暗記（あんき）」に由来します——は世界で最も広く使われている[間隔反復システム（SRS）](https://en.wikipedia.org/wiki/Spaced_repetition)であり、とても重要なツールです。

リンク：[Anki 公式サイト](https://apps.ankiweb.net/) · [マニュアル（中国語）](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [（中国語）](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

*[画像：イメージ / 凡例]*

覚えたい素材を Anki に渡せば、最小限の学習時間で最良の定着を得ることができます。

Anki には [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) が組み込まれています——世界でも最高クラスの間隔反復アルゴリズムの一つです。

**ただし！！！** Anki のデフォルトのアルゴリズムは SM2 で、30 年以上前の性能の低いアルゴリズムです。Anki が使用するアルゴリズムを必ず **FSRS** に切り替えてください。

#### Anki

##### Android

1. Anki をインストールして開きます。
2. hibiki に戻り、設定 -> カード作成 を開きます。
3. **デッキとノートタイプを更新**（画像の「1」）をタップします。hibiki が権限を要求するので——「許可」をタップします。
4. **Lapis デッキを作成**（画像の「2」）をタップします。
5. 赤い警告やエラーが出なければ、セットアップは成功です。

![Anki Android セットアップ](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Anki をインストールして開きます。
2. 左上の **ツール（Tools）** をクリックします。

![Windows の Anki ツールメニュー](static-assets/user-guide/anki-windows-tools-menu.png)

3. 下記の Anki アドオンコードを貼り付けてインストールします：`2055492159`
4. hibiki に戻り、設定 -> カード作成 を開きます。
5. **デッキとノートタイプを更新**（「1」）をタップします。
6. **Lapis デッキを作成**（「2」）をタップします。
7. 赤い警告やエラーが出なければ、セットアップは成功です。

![Anki Windows セットアップ](static-assets/user-guide/anki-windows-setup.png)

### 3. 設定の各項目に目を通し、調整したいものがないか確認してください。（任意）

## 謝辞

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
