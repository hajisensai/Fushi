<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="логотип Fushi" width="160">

![Платформа](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-lightgrey)
![Лицензия](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | **Русский** | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Скачать последнюю версию](https://img.shields.io/badge/%E2%AC%87%20%D0%A1%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C%20%D0%BF%D0%BE%D1%81%D0%BB%D0%B5%D0%B4%D0%BD%D1%8E%D1%8E%20%D0%B2%D0%B5%D1%80%D1%81%D0%B8%D1%8E-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Присоединиться к Discord](https://img.shields.io/badge/%D0%9F%D1%80%D0%B8%D1%81%D0%BE%D0%B5%D0%B4%D0%B8%D0%BD%D0%B8%D1%82%D1%8C%D1%81%D1%8F%20%D0%BA%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Поддержка платформ

| Платформа | Статус | Рендеринг / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material Design 3 |
| macOS | ✅ | Material Design 3 |
| Linux | 🔧 (build from source) | Material Design 3 |
| iOS | ✅ | Material Design 3 |

> Минимум Android 7.0 (API 24). Языки, доступные для поиска по словарю, определяются импортированными словарями и таблицами трансформации Yomitan, независимо от языка интерфейса.

### Языки интерфейса (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Установка и сборка

Подготовка одной командой (`flutter pub get` + применение патчей), затем сборка:

```bash
# из корня репозитория
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Windows desktop
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` сводят `flutter pub get` и `ci/apply-patches.sh` в одну команду. Проект привязан к Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); часть upstream-зависимостей vendored в `third_party/` или патчится через `ci/apply-patches.sh` — подробности см. в [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Технологический стек</b></summary>

| Уровень | Технология |
|---|---|
| Фреймворк | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Платформы | Android / Windows / macOS / iOS (Material Design 3) |
| Читалка | Постраничный движок на WebView (на основе семейства Hoshi Reader) |
| Видео | media_kit (ядро libmpv) |
| Хранение | Drift (SQLite, WAL) + fushidicts (движок словарей C++ FFI) |
| NLP | Таблицы трансформации Yomitan (многоязычная лемматизация) + kana_kit (конвертация кана); сегментация через fushidicts FFI |
| Создание карточек | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 языков) |

</details>

<details>
<summary><b>Структура проекта</b></summary>

```
Fushi/                      # Корень репозитория (Melos workspace: fushi_workspace)
├── fushi/                  # Основной каталог Flutter-приложения
│   ├── lib/
│   │   ├── i18n/            # Интернационализация (17 языков, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Страницы (книжная полка, читалка, словарь, настройки и др.)
│   │   │   ├── reader/      # JS/CSS-скрипты WebView читалки
│   │   │   ├── media/       # Аудиокниги, разбор субтитров, reader source
│   │   │   └── models/      # Модели данных и управление состоянием (AppModel)
│   │   └── main.dart
│   └── android/             # Android-проект (manifest, native fushidicts)
├── packages/                # Внутренние пакеты + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # Движок словарей C++ fushidicts (FFI)
├── third_party/             # Vendored патч-пакеты (dependency_overrides)
├── ci/                      # Патчи сборки и скрипты интеграционных тестов
├── tool/                    # Скрипты bootstrap / i18n_sync и др.
└── docs/                    # Документация разработки (включая руководство по операциям docs/agent/)
```

</details>

## Конфиденциальность и данные

Fushi хранит импортированные книги, словари, шрифты, данные аудиокниг, видео, прогресс чтения, подсветки, статистику и настройки в локальном хранилище приложения.

Облачная синхронизация (Google Drive / OneDrive / Dropbox) использует настроенные пользователем учётные данные OAuth; WebDAV / FTP / SFTP использует предоставленные пользователем адреса серверов и учётные данные; Fushi Interconnect подключается напрямую по настроенному пользователем адресу. Создание карточек Anki взаимодействует с AnkiDroid или настроенным адресом AnkiConnect.

## Благодарности

Fushi опирается на следующие проекты и экосистему:

| Проект | Описание |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Инструмент иммерсивного изучения японского |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Читалка японского для iOS; референс постраничного движка |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Нативная читалка японского для Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Движок словарей C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Решение для синхронизации аудиокниг |
| [Yomitan](https://github.com/yomidevs/yomitan) | Референс формата словарей, таблиц трансформации и опыта поиска |
| [Lapis](https://github.com/donkuri/lapis) | Тип заметки Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Интеграция создания карточек на Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Референс локального аудио и взаимодействия с AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Референс совместимости читалки, статистики и синхронизации |
| [media_kit](https://github.com/media-kit/media-kit) | Фреймворк воспроизведения видео для Flutter (ядро libmpv) |
| [Niratan](https://github.com/W1ght/Niratan) | Набор для иммерсивного изучения языков для macOS |

## Лицензия

Распространяется под лицензией GNU General Public License v3.0. Подробности см. в [LICENSE](../../LICENSE).

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | **Русский** | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
