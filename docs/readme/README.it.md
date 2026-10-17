<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="logo Fushi" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | **Italiano** | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Scarica l'ultima versione](https://img.shields.io/badge/%E2%AC%87%20Scarica%20l%27ultima%20versione-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Unisciti a Discord](https://img.shields.io/badge/Unisciti%20a%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Supporto delle piattaforme

| Piattaforma | Stato | Note |
|---|---|---|
| Android | ✅ | Android 7.0 (API 24) o successivo |
| Windows | ✅ | L'hooking di testo e voce dei galgame è disponibile solo su Windows |
| macOS | ✅ | Solo Apple Silicon; i Mac Intel non sono supportati |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | Niente scoperta, fonti online né centro download (linee guida dell'App Store) |
| Linux | 🔧 Da compilare dai sorgenti | Non c'è ancora una versione precompilata; il lettore EPUB richiede WPE WebKit |
| Fushi Server | 🧪 Beta ([fushi-server](https://github.com/hajisensai/fushi-server/releases)) | Host headless per Linux / Windows / macOS con interfaccia web — vedi [packages/fushi_server](../../packages/fushi_server/README.md) |

**Sistema di design** — tutte le piattaforme usano per impostazione predefinita **Material 3 Expressive**; un sistema di design **Cupertino** (in stile Apple) può essere selezionato in *Impostazioni › Aspetto › Sistema di design*; con Cupertino lo sfondo della finestra usa Mica su Windows 11 e vibrancy su macOS (a meno che non sia attiva l'impostazione di sistema per ridurre la trasparenza o per l'alto contrasto).

> Le lingue disponibili per la ricerca nei dizionari sono determinate dai dizionari importati e dalle tabelle di trasformazione di Yomitan, indipendentemente dalla lingua dell'interfaccia. Gli aggiornamenti iOS arrivano tramite TestFlight qualche giorno dopo rispetto alle altre piattaforme.

### Lingue dell'interfaccia (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Installazione

Scarica l'ultima versione dal [sito web di Fushi](https://fushi.moe/): sono disponibili l'APK per Android, il programma di installazione per Windows e le build per macOS (solo Apple Silicon; i Mac Intel non sono supportati); iOS si installa tramite [TestFlight](https://testflight.apple.com/join/j88d69jx). Per Linux non esiste ancora una versione precompilata dell'app; compilala dai sorgenti. Fushi Server, il server headless, viene rilasciato separatamente su [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server/releases).

> Richiede Android 7.0 (API 24) o superiore.

## Compilazione

Preparazione con un solo comando (`flutter pub get` + applicazione delle patch), poi compila:

```bash
# Dalla radice del repository
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Desktop
flutter build windows --release
flutter build macos --release
flutter build linux --release
# iOS
flutter build ipa --release

# Server headless (da packages/fushi_server; usa `dart build cli`, non `dart compile exe`)
dart build cli
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` riuniscono `flutter pub get` e `ci/apply-patches.sh` in un unico comando. Questo progetto è bloccato su Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`); le versioni precedenti di Flutter non riescono a compilarlo perché Material e Cupertino sono usati come i pacchetti `material_ui` / `cupertino_ui`. Alcune dipendenze upstream sono incluse in `third_party/` o patchate da `ci/apply-patches.sh`; consulta [docs/agent/build.md](../agent/build.md) per i dettagli, comprese le dipendenze di compilazione del desktop Linux.

<details>
<summary><b>Stack tecnologico</b></summary>

| Livello | Tecnologia |
|---|---|
| Framework | Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`), Riverpod |
| Piattaforme | Android / Windows / macOS / iOS / Linux, più un server headless |
| UI | `material_ui` (Material 3 Expressive) / `cupertino_ui` (Cupertino) |
| Lettore | Motore di impaginazione WebView (derivato dalla famiglia Hoshi Reader) |
| Video | media_kit (libmpv core) + libplacebo |
| Archiviazione | Drift (SQLite, WAL) + fushidicts (motore di dizionari FFI in C++) |
| NLP | Tabelle di trasformazione di Yomitan (lemmatizzazione multilingue) + kana_kit (conversione dei kana); tokenizzazione tramite fushidicts FFI |
| IA sul dispositivo | ONNX Runtime per il riconoscimento vocale (generazione di sottotitoli) e l'OCR dei manga; gli algoritmi risiedono in [fushi-subtitles](https://github.com/hajisensai/fushi-subtitles) |
| Download | libtorrent 2.x tramite un ponte FFI con C-ABI (qBittorrent esterno come alternativa) |
| Sincronizzazione | Backend cloud + Fushi Interconnect (LAN, indirizzi remoti e un tunnel P2P iroh) |
| Motore condiviso | `fushi_engine`: nucleo in puro Dart condiviso da app e Fushi Server |
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
│   │   │   ├── pages/       # Pagine (pagine della libreria, lettore, player video, impostazioni, ecc.)
│   │   │   ├── reader/      # Script JS/CSS del WebView del lettore
│   │   │   ├── media/       # Libri, manga, video, audiolibri, fonti online
│   │   │   ├── lookup/      # Popup e overlay di ricerca nei dizionari
│   │   │   ├── mining/      # Creazione di carte (incl. mining dei galgame)
│   │   │   ├── sync/        # Sincronizzazione cloud, Interconnect, media server
│   │   │   └── models/      # Modelli di dati e gestione dello stato (AppModel)
│   │   └── main.dart
│   └── android/             # Progetto Android
├── packages/                # Pacchetti Dart
│   ├── fushi_core/          #   Schema del database, preferenze
│   ├── fushi_engine/        #   Motore in puro Dart condiviso con il server
│   ├── fushi_server/        #   CLI del server headless + interfaccia web
│   ├── fushi_cli/           #   Client a riga di comando per desktop
│   ├── fushi_dictionary/    #   Binding del motore di dizionari e importatori
│   ├── fushi_anki/ · fushi_audio/ · fushi_platform/ · fushi_srs/
│   ├── fushi_torrent/ · fushi_p2p/   # Binding FFI di libtorrent / iroh
│   └── …                    #   Fork inclusi (inappwebview Windows/Linux, gamepads)
├── native/                  # Sorgenti nativi: fushidicts, fushi_torrent, fushi_p2p (Rust), galgame_hook, …
├── services/                # Raccolta dei log e backend della classifica (distribuiti separatamente)
├── tools/browser-extension/ # Estensione del browser per la ricerca nei dizionari
├── third_party/             # Pacchetti con patch inclusi (dependency_overrides)
├── ci/                      # Patch di compilazione e script di CI
├── tool/                    # Script bootstrap / setup_worktree / tracciamento dei bug
└── docs/                    # Documentazione di sviluppo (incl. manuale operativo docs/agent/)
```

</details>

L'importazione dei video supporta il raggruppamento per opera o per cartella. Consulta il [flusso di lavoro dei video](../specs/2026-09-07-video-library-workflow.md) e i [metadati MAL/TMDB con hashing dei file AniDB](../specs/2026-09-07-mal-tmdb-anidb-hash.md) per l'abbinamento e le attività in background.

La [configurazione facoltativa dei servizi online](../specs/2026-09-07-online-services-setup.md) spiega le identità applicative incluse, le credenziali personali e il promemoria di configurazione video che si può chiudere.

## Privacy e dati

Fushi memorizza i libri importati, i dizionari, i caratteri, i dati degli audiolibri, i video, l'avanzamento di lettura, le evidenziazioni, le statistiche e le impostazioni nell'archiviazione locale dell'app.

- **Sincronizzazione** — Google Drive / OneDrive / Dropbox usano l'accesso OAuth; WebDAV / FTP / SFTP / Fushi Server usano l'indirizzo del server e le credenziali che fornisci. Fushi Interconnect collega direttamente i dispositivi associati (LAN, IPv6, reti overlay o indirizzi pubblici) e, quando nessun percorso diretto funziona, ripiega su un tunnel P2P iroh end-to-end; i link di associazione chiedono sempre conferma.
- **Anki** — la creazione di carte comunica con AnkiDroid o con l'indirizzo AnkiConnect che configuri.
- **Statistiche di utilizzo** — una volta al giorno, le build per desktop e Android inviano a fushi.moe un ID di installazione casuale, la versione dell'app, la piattaforma e il canale di aggiornamento per contare gli utenti attivi; non è incluso alcun account, libreria o dato di lettura e gli indirizzi IP non vengono memorizzati. Disattivale con *Condividi statistiche di utilizzo* nelle impostazioni di aggiornamento. Le build iOS non le inviano.
- **Solo quando lo richiedi** — il caricamento dei log (dopo una singola richiesta di consenso), il feedback nell'app e la classifica (disattivata per impostazione predefinita; carica i titoli della tua libreria e l'avanzamento solo dopo che hai dato il consenso).
- **OCR dei manga** — il motore predefinito è Google Lens, che invia l'immagine della pagina a Google; passa al modello sul dispositivo o all'OCR di sistema nelle impostazioni per mantenere le immagini in locale.
- **Funzioni di IA** — le richieste vanno solo al provider LLM che configuri e assegni a una funzione; se non è assegnato alcun provider, non viene inviato nulla.
- **Servizi di terze parti** — le funzioni di metadati, sottotitoli e fonti online contattano i servizi elencati in [Fonti di contenuti e integrazioni](#fonti-di-contenuti-e-integrazioni) solo quando le usi.

## Attività di sviluppo

[![Attività di sviluppo](../assets/dev-activity.svg)](https://github.com/hajisensai/Fushi/commits/develop)

Il lavoro quotidiano confluisce su `develop`; `main` riceve solo i merge di rilascio. Il grafico viene mostrato qui su `main` ma è generato a partire da `develop`, quindi riflette lo sviluppo reale e non il traffico di merge.

Le tre corsie sono i canali di aggiornamento offerti dall'app stessa, e ciascuna è scalata sul proprio picco: le build debug superano le versioni stabili di due ordini di grandezza, quindi una scala comune ridurrebbe le altre due corsie a quasi nulla.

| Corsia | Cosa conta | Come ottenerla |
|---|---|---|
| **Debug (continua)** | Build riuscite a ogni push di [release.yml](../../.github/workflows/release.yml) | Pre-release continua, ripubblicata a ogni push |
| **Beta** | Pre-release `v<version>-beta.<seq>` | Build di test avviata manualmente |
| **Stabile** | Release `v<version>` | Ultima release |

> Il grafico qui sopra è generato all'interno di questo repository (senza servizi di terze parti) e aggiornato ogni giorno dal workflow [Update Dev Activity Chart](../../.github/workflows/dev-activity.yml).

## Cronologia delle stelle

[![GitHub stars](https://img.shields.io/github/stars/hajisensai/Fushi?style=flat&logo=github&label=Stars)](https://github.com/hajisensai/Fushi/stargazers)

[![Star History](../assets/star-history.svg)](https://github.com/hajisensai/Fushi/stargazers)

> Il grafico qui sopra è generato all'interno di questo repository (senza servizi di terze parti) e aggiornato ogni giorno dal workflow [Update Star History](../../.github/workflows/star-history.yml).

## Ringraziamenti

Fushi si basa sui seguenti progetti ed ecosistema:

### Strumenti di apprendimento e riferimenti

| Progetto | Descrizione |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Strumento di apprendimento immersivo del giapponese |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Lettore di giapponese per iOS; riferimento per il motore di impaginazione del lettore |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Lettore di giapponese nativo per Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Motore di dizionari in C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Soluzione di sincronizzazione degli audiolibri |
| [Tsubasa](https://github.com/SonicSandbox/Tsubasa-sync) | Algoritmo di allineamento temporale dei sottotitoli rispetto a un riferimento (GPL-3.0); base per l'allineamento automatico dei sottotitoli scaricati alle tracce incorporate |
| [Yomitan](https://github.com/yomidevs/yomitan) | Riferimento per formato dei dizionari, tabelle di trasformazione ed esperienza di ricerca |
| [Lapis](https://github.com/donkuri/lapis) | Tipo di nota di Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Integrazione della creazione di carte su Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Riferimento per l'audio locale e l'interazione con AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Riferimento di compatibilità per lettore, statistiche e sincronizzazione |
| [media_kit](https://github.com/media-kit/media-kit) | Framework Flutter per la riproduzione video (nucleo libmpv) |
| [Niratan](https://github.com/W1ght/Niratan) | Suite di apprendimento linguistico immersivo per macOS |

### Motori e componenti nativi

| Progetto | Descrizione |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | Motore di hooking del testo dei galgame (DLL incluse, caricate dall'iniettore) |
| [MinHook](https://github.com/TsudaKageyu/minhook) | Libreria di inline hooking usata dall'iniettore dei galgame |
| [libtorrent](https://github.com/arvidn/libtorrent) | Motore di download torrent integrato |
| [mpv](https://github.com/mpv-player/mpv) | Nucleo di riproduzione libmpv alla base di media_kit |
| [FFmpeg](https://ffmpeg.org) | Analisi dei media, ritaglio ed estrazione dell'audio |
| [libplacebo](https://github.com/haasn/libplacebo) | Shader video su GPU e tone mapping HDR |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | Motore WebView che renderizza il lettore EPUB |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | Inferenza sul dispositivo per riconoscimento vocale e OCR |
| [iroh](https://github.com/n0-computer/iroh) | Tunnel P2P per le connessioni remote di Fushi Interconnect |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | Dipendenze del motore di dizionari |

### Modelli sul dispositivo

| Progetto | Descrizione |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Pacchetti di modelli Zipformer di riconoscimento vocale e build VAD |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | Modello di riconoscimento vocale per il giapponese |
| [Parakeet TDT-CTC 0.6B ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) | Modello di riconoscimento vocale per il giapponese |
| [Kitsune](https://huggingface.co/subthx/kitsune-onnx) | Modello di riconoscimento vocale per il giapponese (CC BY-NC 4.0, scaricato dal suo repository Hugging Face) |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | Modello multilingue di riconoscimento vocale CTC |
| [Silero VAD](https://github.com/snakers4/silero-vad) | Modello di rilevamento dell'attività vocale |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | Modello di rilevamento di testo e nuvolette dei manga |
| [manga-panel-detector-yolo26n](https://huggingface.co/leoxs22/manga-panel-detector-yolo26n) | Modello di rilevamento delle vignette dei manga, addestrato con [Manga109-s](http://www.manga109.org/en/download_s.html) |
| [PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR) small det / rec · [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga) | Rilevamento e riconoscimento delle righe di testo; il rec adattato ai manga (addestrato con [Manga109-s](http://www.manga109.org/en/download_s.html) e [AnimeText](https://huggingface.co/datasets/deepghs/AnimeText)) alimenta il modello OCR locale CTC per colonna |

> Il modello di rilevamento delle vignette dei manga e PP-OCRv6_manga sono addestrati con il dataset Manga109-s (Matsui et al. 2017; Aizawa et al. 2020), i cui termini richiedono di indicare chiaramente questo uso del dataset. PP-OCRv6_manga (Apache-2.0) è inoltre addestrato con il dataset AnimeText, rilasciato con licenza CC BY-NC-SA 4.0; l'app scarica quel modello dal suo repository Hugging Face e non lo ridistribuisce.

### Fonti di contenuti e integrazioni

| Progetto | Descrizione |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | Ecosistema di estensioni di fonti per manga |
| [Aniyomi](https://github.com/aniyomiorg/aniyomi) | Ecosistema di estensioni di fonti per anime (extensions-lib 14–16, ospitate dallo stesso runtime) |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | Runtime di estensioni manga per desktop (incluso, MPL-2.0) |
| [Mangayomi](https://github.com/kodjodevf/mangayomi) | Riferimento per l'adattamento delle estensioni Mihon / Aniyomi |
| [LNReader](https://github.com/LNReader/lnreader-plugins) | Ecosistema di plugin di fonti per light novel |
| [Jellyfin](https://jellyfin.org) · [Emby](https://emby.media) · [Plex](https://www.plex.tv) | Media server navigabili dalla libreria video |
| [asbplayer](https://github.com/asbplayer/asbplayer) | Riferimento per il ponte dei sottotitoli in streaming dell'estensione del browser |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | Riferimento architetturale per identificazione e scraping degli anime |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | Riferimento per l'architettura dell'informazione della libreria di galgame |
| [AniDB](https://anidb.net) | Identità di anime, episodi e file |
| [MyAnimeList](https://myanimelist.net) (tramite [Jikan](https://jikan.moe)) | Metadati degli anime |
| [TMDB](https://www.themoviedb.org) | Metadati e immagini complementari |
| [VNDB](https://vndb.org) | Metadati delle visual novel |
| [Jimaku](https://jimaku.cc) | Fonte di sottotitoli giapponesi |
| [OpenSubtitles](https://www.opensubtitles.com) | Fonte di sottotitoli |

> Questa applicazione utilizza TMDB e le API TMDB ma non è approvata, certificata o altrimenti autorizzata da TMDB.

## Licenza

Distribuito sotto la GNU General Public License v3.0. Vedi [LICENSE](../../LICENSE) per i dettagli.

## Manutentore

Fushi è mantenuto da [hajisensai](https://github.com/hajisensai). Sito web: [fushi.moe](https://fushi.moe). Contatto: [contact@fushi.moe](mailto:contact@fushi.moe).

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | **Italiano** | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
