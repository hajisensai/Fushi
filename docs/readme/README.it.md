<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">Lettore immersivo di giapponese per Android</p>
<p align="center">EPUB · Dizionario · Anki · Sincronizzazione audiolibri</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <b>Italiano</b> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Introduzione

**hibiki** è un'app di lettura per Android destinata agli studenti di giapponese.

## Funzionalità

### Lettura EPUB
- Rendering EPUB in WebView (motore di impaginazione derivato da [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader))
- Tocca per cercare nel dizionario, seleziona per analizzare
- Font personalizzati, temi (chiaro/scuro)
- Statistiche di lettura e segnalibri
- Scorrimento continuo / modalità a pagine

### Dizionario
- Importa dizionari in formato [Yomitan](https://github.com/yomidevs/yomitan) (ex Yomichan)
- Supporto per accento tonale e dati di frequenza
- Ricerca parallela su più dizionari, cronologia ricerche
- Deconiugazione Ve

### Schede Anki
- Esportazione con un tocco verso [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- Compilazione automatica delle frasi di contesto
- Registrazione audio, ritaglio screenshot
- Profili di esportazione multipli, mappatura personalizzata dei campi
- Azioni rapide (Quick Actions) per la creazione di schede in un solo passaggio

### Sincronizzazione audiolibri (Sasayaki)
- Formati sottotitoli: SRT / LRC / VTT / ASS
- Allineamento automatico del testo dei sottotitoli al contenuto EPUB
- Evidenziazione sincronizzata, cambio pagina sincronizzato con l'audio
- Controlli di riproduzione (progresso, ricerca, velocità)

### Altro
- 17 lingue dell'interfaccia
- Profili utente multipli
- Modalità in incognito
- Condivisione testo da altre app per la ricerca

## Lingue supportate

L'interfaccia supporta le seguenti lingue:

| Lingua | Codice |
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

## Stack tecnologico

| Livello | Tecnologia |
|---|---|
| Framework | Flutter 3.41.6 (Dart SDK `>=3.5.0 <4.0.0`) |
| Piattaforma | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino adattivo) |
| Lettore | Motore di impaginazione WebView (derivato da [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Archiviazione | Drift (SQLite, WAL) + hoshidicts (motore dizionario C++ FFI) |
| NLP | Ve (deconiugazione) |
| Schede | AnkiDroid API |
| Internazionalizzazione | Slang (17 lingue) |
| Versione minima | Android 7.0 (API 24) |

## Compilazione

Preparazione con un solo comando (genera automaticamente `dart_defines.env` + `flutter pub get` + applica le patch), poi compila:

```bash
# nella radice del repository
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # oppure (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi \
  --dart-define-from-file=dart_defines.env
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` raccoglie tre passaggi in un unico comando: ① se manca `hibiki/dart_defines.env`, viene generato automaticamente da `dart_defines.env.example` (valori OAuth segnaposto bastano per compilare, solo il backup su Google Drive richiede valori reali); ② `flutter pub get`; ③ esecuzione di `ci/apply-patches.sh`. `melos bootstrap` esegue i passaggi ②③ tramite un post-hook (su Windows melos ha un bug di codifica CJK, quindi usa `tool/bootstrap.ps1`).

> **Nota sulle patch:** `ci/apply-patches.sh` sovrascrive la pub cache reale con le modifiche in `ci/patches/`. Va rieseguito dopo ogni svuotamento della pub cache o nuovo `flutter pub get` (bootstrap include già questo passaggio). Se lo script non trova alcun obiettivo di patch, salta e avvisa invece di fingere il successo.

## Dipendenze e patch

Questo progetto è bloccato su Flutter 3.41.6; alcune dipendenze upstream non sono ancora compatibili. Le correzioni seguono due vie: ① i pacchetti che devono fungere da input di build ed essere riprodotti in modo coerente tra macchine vengono vendorizzati direttamente in `third_party/` e referenziati tramite `dependency_overrides` (`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`, **senza** patch alla pub cache); ② i restanti pacchetti vengono patchati da `ci/apply-patches.sh` nel codice sorgente della pub cache. Dettagli del meccanismo in [docs/agent/build.md](../agent/build.md). Le tabelle pieghevoli seguenti sono un elenco storico raggruppato per modifica; in caso di sovrapposizione con il meccanismo ①, prevale la versione vendorizzata.

<details>
<summary><b>Patch per modifiche API di Flutter</b></summary>

| Pacchetto | Modifiche |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`; `DecoderCallback` → `ImageDecoderCallback`; `hashValues` → `Object.hash`; `instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`; sostituzione di `imageCache.putIfAbsent` rimosso |
| `flutter_blurhash` 0.7.0 | Come sopra: `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`; `subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | Aggiunta `hide CarouselController` all'import interno per evitare conflitti di nomi |
| `fading_edge_scrollview` 3.0.0 | Correzione nullable per `PageView.controller` |

</details>

<details>
<summary><b>Patch per rimozione v1 Embedding</b></summary>

Flutter 3.41.6 ha rimosso completamente l'API v1 embedding (`PluginRegistry.Registrar`). I seguenti plugin richiedono la rimozione dei riferimenti correlati:

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Patch Gradle / Kotlin</b></summary>

| Obiettivo | Modifiche |
|---|---|
| `android/build.gradle` afterEvaluate | Forzatura `compileSdk` (predefinito 36, alcuni 34) per i sotto-progetti; rimozione di `-Werror` |
| `audio_session` 0.1.14 | Rimozione di `-Werror`, `-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | Correzione null safety per Kotlin |
| `receive_intent` (git) | Correzione null safety per Kotlin |

</details>

<details>
<summary><b>Dipendenze Git</b></summary>

| Pacchetto | Origine |
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

## Struttura del progetto

```
hibiki/                      # Radice del repository (workspace Melos: hibiki_workspace)
├── hibiki/                  # Directory principale dell'app Flutter
│   ├── lib/
│   │   ├── i18n/            # Internazionalizzazione (17 lingue, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pagine (libreria, lettore, dizionario, impostazioni, ecc.)
│   │   │   ├── reader/      # Script JS/CSS della WebView del lettore
│   │   │   ├── media/       # Audiolibri, parsing sottotitoli, reader source
│   │   │   └── models/      # Modelli dati e gestione dello stato (AppModel)
│   │   └── main.dart
│   └── android/             # Progetto Android (manifest, hoshidicts nativo)
├── packages/                # Pacchetti interni + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── third_party/             # Pacchetti patch vendorizzati (referenziati da dependency_overrides)
├── ci/                      # Patch di build e script di test di integrazione
├── tool/                    # Script bootstrap / i18n_sync, ecc.
└── docs/                    # Documentazione di sviluppo (incl. manuale agente docs/agent/)
```

## Ringraziamenti

| Progetto | Descrizione |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Strumento di apprendimento immersivo del giapponese |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Lettore giapponese per Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Motore dizionario C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Lettore giapponese per iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Schema di sincronizzazione audiolibri |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Motore di rendering EPUB |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | Versione mantenuta dalla comunità ttu (SvelteKit v2), base upstream del fork hibiki |
| [Yomitan](https://github.com/yomidevs/yomitan) | Origine del formato dizionario |

## Licenza

[GNU General Public License v3.0](../../LICENSE)
