<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="logo Fushi" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | **Italiano** | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Scarica l'ultima versione](https://img.shields.io/badge/%E2%AC%87%20Scarica%20l%27ultima%20versione-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Unisciti a Discord](https://img.shields.io/badge/Unisciti%20a%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Supporto delle piattaforme

| Piattaforma | Stato | Rendering / Interfaccia |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material Design 3 |
| macOS | ✅ | Material Design 3 |
| Linux | 🔧 (build from source) | Material Design 3 |
| iOS | ✅ | Material Design 3 |

> Minimo Android 7.0 (API 24). Le lingue disponibili per la ricerca nei dizionari sono determinate dai dizionari importati e dalle tabelle di trasformazione di Yomitan, indipendentemente dalla lingua dell'interfaccia.

### Lingue dell'interfaccia (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Installazione e compilazione

Preparazione con un solo comando (`flutter pub get` + applicazione delle patch), poi compila:

```bash
# Dalla radice del repository
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Desktop Windows
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` racchiudono `flutter pub get` e `ci/apply-patches.sh` in un unico comando. Questo progetto è bloccato su Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); alcune dipendenze upstream sono incluse in `third_party/` o sottoposte a patch da `ci/apply-patches.sh` — vedi [docs/agent/build.md](../agent/build.md) per i dettagli.

<details>
<summary><b>Stack tecnologico</b></summary>

| Livello | Tecnologia |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Piattaforme | Android / Windows / macOS / iOS (Material Design 3) |
| Lettore | Motore di impaginazione WebView (derivato dalla famiglia Hoshi Reader) |
| Video | media_kit (libmpv core) |
| Archiviazione | Drift (SQLite, WAL) + fushidicts (motore di dizionari FFI in C++) |
| NLP | Tabelle di trasformazione di Yomitan (lemmatizzazione multilingue) + kana_kit (conversione kana); tokenizzazione tramite fushidicts FFI |
| Creazione di carte | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 lingue) |

</details>

<details>
<summary><b>Struttura del progetto</b></summary>

```
Fushi/                      # Radice del repository (workspace Melos: fushi_workspace)
├── fushi/                  # Directory principale dell'app Flutter
│   ├── lib/
│   │   ├── i18n/            # Internazionalizzazione (17 lingue, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pagine (libreria, lettore, dizionario, impostazioni, ecc.)
│   │   │   ├── reader/      # Script JS/CSS del WebView del lettore
│   │   │   ├── media/       # Audiolibri, analisi dei sottotitoli, sorgente del lettore
│   │   │   └── models/      # Modelli di dati e gestione dello stato (AppModel)
│   │   └── main.dart
│   └── android/             # Progetto Android (manifest, fushidicts nativo)
├── packages/                # Pacchetti interni + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # Motore di dizionari in C++ fushidicts (FFI)
├── third_party/             # Pacchetti con patch inclusi (dependency_overrides)
├── ci/                      # Patch di compilazione e script per i test di integrazione
├── tool/                    # Script bootstrap / i18n_sync e altri
└── docs/                    # Documentazione di sviluppo (incl. manuale operativo docs/agent/)
```

</details>

## Privacy e dati

Fushi memorizza i libri importati, i dizionari, i caratteri, i dati degli audiolibri, i video, l'avanzamento di lettura, le evidenziazioni, le statistiche e le impostazioni nell'archiviazione locale dell'app.

La sincronizzazione nel cloud (Google Drive / OneDrive / Dropbox) utilizza credenziali OAuth configurate dall'utente; WebDAV / FTP / SFTP utilizza indirizzi del server e credenziali forniti dall'utente; Fushi Interconnect si connette direttamente tramite un indirizzo configurato dall'utente. La creazione di carte Anki comunica con AnkiDroid o con un indirizzo AnkiConnect configurato.

## Ringraziamenti

Fushi si basa sui seguenti progetti ed ecosistema:

| Progetto | Descrizione |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Strumento di apprendimento immersivo del giapponese |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Lettore di giapponese per iOS; riferimento per il motore di impaginazione del lettore |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Lettore di giapponese nativo per Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Motore di dizionari in C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Soluzione di sincronizzazione degli audiolibri |
| [Yomitan](https://github.com/yomidevs/yomitan) | Riferimento per formato del dizionario, tabelle di trasformazione ed esperienza di ricerca |
| [Lapis](https://github.com/donkuri/lapis) | Tipo di nota Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Integrazione della creazione di carte su Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Riferimento per audio locale e interazione con AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Riferimento per compatibilità di lettore, statistiche e sincronizzazione |
| [media_kit](https://github.com/media-kit/media-kit) | Framework di riproduzione video di Flutter (core libmpv) |
| [Niratan](https://github.com/W1ght/Niratan) | Suite di apprendimento immersivo delle lingue per macOS |

## Licenza

Distribuito sotto la GNU General Public License v3.0. Vedi [LICENSE](../../LICENSE) per i dettagli.

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | **Italiano** | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
