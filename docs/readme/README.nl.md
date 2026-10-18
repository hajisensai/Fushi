<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="fushi-logo" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | **Nederlands** | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Nieuwste versie downloaden](https://img.shields.io/badge/%E2%AC%87%20Nieuwste%20versie%20downloaden-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Word lid van Discord](https://img.shields.io/badge/Word%20lid%20van%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Platformondersteuning

| Platform | Status | Opmerkingen |
|---|---|---|
| Android | ✅ | Android 7.0 (API 24) of hoger |
| Windows | ✅ | Het hooken van galgame-tekst en -stem werkt alleen op Windows |
| macOS | ✅ | Alleen Apple Silicon; Intel-Macs worden niet ondersteund |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | Geen ontdekken, online bronnen of downloadcentrum (App Store-richtlijnen) |
| Linux | 🔧 Zelf bouwen vanuit de broncode | Nog geen kant-en-klare release; de EPUB-lezer vereist WPE WebKit |
| Fushi Server | 🧪 Bèta ([fushi-server](https://github.com/hajisensai/fushi-server/releases)) | Headless host voor Linux / Windows / macOS met een webinterface — zie [packages/fushi_server](../../packages/fushi_server/README.md) |

**Ontwerpsysteem** — op elk platform is **Material 3 Expressive** de standaard; een **Cupertino**-ontwerpsysteem (in Apple-stijl) kun je kiezen via *Instellingen › Uiterlijk › Ontwerpsysteem*; met Cupertino gebruikt de vensterachtergrond Mica op Windows 11 en vibrancy op macOS (tenzij de systeeminstelling voor minder transparantie of hoog contrast aanstaat).

> Welke talen beschikbaar zijn om op te zoeken, wordt bepaald door de geïmporteerde woordenboeken en de Yomitan-transformatietabellen, onafhankelijk van de interfacetaal. iOS-updates komen via TestFlight een paar dagen later dan op de andere platforms.

### Interfacetalen (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Installatie

Download de nieuwste versie van de [Fushi-website](https://fushi.moe/) — er zijn een Android-APK, een Windows-installatieprogramma en macOS-builds beschikbaar (alleen Apple Silicon; Intel-Macs worden niet ondersteund); iOS wordt geïnstalleerd via [TestFlight](https://testflight.apple.com/join/j88d69jx). Voor Linux bestaat nog geen kant-en-klare app-release; bouw de app vanuit de broncode. De headless Fushi Server wordt apart uitgebracht op [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server/releases).

> Vereist Android 7.0 (API 24) of hoger.

## Bouwen

Voorbereiding met één commando (`flutter pub get` + patches toepassen), dan bouwen:

```bash
# Vanuit de hoofdmap van de repository
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

# Headless server (vanuit packages/fushi_server; gebruik `dart build cli`, niet `dart compile exe`)
dart build cli
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` bundelen `flutter pub get` en `ci/apply-patches.sh` tot één enkel commando. Dit project is vastgezet op Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`); eerdere Flutter-versies kunnen het niet bouwen, omdat Material en Cupertino worden gebruikt als de pakketten `material_ui` / `cupertino_ui`. Sommige upstream-afhankelijkheden zijn meegeleverd onder `third_party/` of gepatcht door `ci/apply-patches.sh` — zie [docs/agent/build.md](../agent/build.md) voor details, inclusief de bouwafhankelijkheden voor de Linux-desktop.

<details>
<summary><b>Technologiestack</b></summary>

| Laag | Technologie |
|---|---|
| Framework | Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`), Riverpod |
| Platforms | Android / Windows / macOS / iOS / Linux, plus een headless server |
| UI | `material_ui` (Material 3 Expressive) / `cupertino_ui` (Cupertino) |
| Reader | WebView-paginamotor (afgeleid van de Hoshi Reader-familie) |
| Video | media_kit (libmpv-kern) + libplacebo |
| Opslag | Drift (SQLite, WAL) + fushidicts (C++-FFI-woordenboekengine) |
| NLP | Yomitan-transformatietabellen (meertalige lemmatisering) + kana_kit (kana-conversie); tokenisatie via fushidicts-FFI |
| AI op het apparaat | ONNX Runtime voor spraakherkenning (ondertitels genereren) en manga-OCR; de algoritmen staan in [fushi-subtitles](https://github.com/hajisensai/fushi-subtitles) |
| Downloads | libtorrent 2.x via een C-ABI-FFI-brug (externe qBittorrent als terugvaloptie) |
| Synchronisatie | Cloudbackends + Fushi Interconnect (LAN, externe adressen en een iroh-P2P-tunnel) |
| Gedeelde engine | `fushi_engine` — pure-Dart-kern die de app en Fushi Server delen |
| Kaarten maken | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 talen) |

</details>

<details>
<summary><b>Projectstructuur</b></summary>

```
Fushi/                      # Hoofdmap van de repository (Melos-workspace: fushi_workspace)
├── fushi/                  # Hoofdmap van de Flutter-app
│   ├── lib/
│   │   ├── i18n/            # Internationalisatie (17 talen, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pagina's (bibliotheekpagina's, lezer, videospeler, instellingen enz.)
│   │   │   ├── reader/      # Reader-WebView-JS-/CSS-scripts
│   │   │   ├── media/       # Boeken, manga, video, audioboeken, online bronnen
│   │   │   ├── lookup/      # Pop-ups en overlays voor woordenboekopzoeking
│   │   │   ├── mining/      # Kaarten maken (incl. galgame-mining)
│   │   │   ├── sync/        # Cloudsynchronisatie, Interconnect, mediaservers
│   │   │   └── models/      # Datamodellen en toestandsbeheer (AppModel)
│   │   └── main.dart
│   └── android/             # Android-project
├── packages/                # Dart-pakketten
│   ├── fushi_core/          #   Databaseschema, voorkeuren
│   ├── fushi_engine/        #   Pure-Dart-engine die met de server wordt gedeeld
│   ├── fushi_server/        #   Headless server-CLI + webinterface
│   ├── fushi_cli/           #   Opdrachtregelclient voor desktop
│   ├── fushi_dictionary/    #   Woordenboekengine-bindings en importers
│   ├── fushi_anki/ · fushi_audio/ · fushi_platform/ · fushi_srs/
│   ├── fushi_torrent/ · fushi_p2p/   # libtorrent- / iroh-FFI-bindings
│   └── …                    #   Meegeleverde forks (inappwebview Windows/Linux, gamepads)
├── native/                  # Native bronnen: fushidicts, fushi_torrent, fushi_p2p (Rust), galgame_hook, …
├── services/                # Logcollector en leaderboard-backends (apart gedeployed)
├── tools/browser-extension/ # Browserextensie voor opzoeken
├── third_party/             # Meegeleverde gepatchte pakketten (dependency_overrides)
├── ci/                      # Build-patches en CI-scripts
├── tool/                    # bootstrap / setup_worktree / bugtracker-scripts
└── docs/                    # Ontwikkeldocumentatie (incl. docs/agent/ bedieningshandleiding)
```

</details>

Video-import ondersteunt groeperen per werk of map. Zie de [videoworkflow](../specs/2026-09-07-video-library-workflow.md) en [MAL/TMDB-metadata met AniDB-bestandshashing](../specs/2026-09-07-mal-tmdb-anidb-hash.md) voor matching en achtergrondtaken.

[Optionele onlineservice-instelling](../specs/2026-09-07-online-services-setup.md) legt de meegeleverde applicatie-identiteiten, persoonlijke referenties en de te sluiten herinnering voor video-instelling uit.

## Privacy & Gegevens

Fushi slaat geïmporteerde boeken, woordenboeken, lettertypen, audioboekgegevens, video's, leesvoortgang, markeringen, statistieken en instellingen op in de lokale opslag van de app.

- **Synchronisatie** — Google Drive / OneDrive / Dropbox gebruiken OAuth-aanmelding; WebDAV / FTP / SFTP / Fushi Server gebruiken het serveradres en de referenties die je opgeeft. Fushi Interconnect verbindt gekoppelde apparaten rechtstreeks (LAN, IPv6, overlaynetwerken of openbare adressen) en valt terug op een end-to-end iroh-P2P-tunnel als geen directe route werkt; koppelingslinks vragen altijd om bevestiging.
- **Anki** — het maken van kaarten communiceert met AnkiDroid of het AnkiConnect-adres dat je configureert.
- **Gebruiksstatistieken** — eenmaal per dag sturen desktop- en Android-builds een willekeurig installatie-ID, de appversie, het platform en het updatekanaal naar fushi.moe om actieve gebruikers te tellen; er worden geen account-, bibliotheek- of leesgegevens meegestuurd en IP-adressen worden niet opgeslagen. Schakel het uit met *Gebruiksstatistieken delen* in de update-instellingen. iOS-builds sturen dit niet.
- **Alleen als je erom vraagt** — het uploaden van logs (na een eenmalige toestemmingsvraag), feedback in de app en het leaderboard (standaard uit; uploadt je bibliotheektitels en voortgang pas nadat je je aanmeldt).
- **Manga-OCR** — de standaardengine is Google Lens, die de pagina-afbeelding naar Google stuurt; schakel in de instellingen over op het model op het apparaat of systeem-OCR om afbeeldingen lokaal te houden.
- **AI-functies** — verzoeken gaan alleen naar de LLM-provider die je configureert en aan een functie toewijst; zonder toegewezen provider wordt niets verzonden.
- **Diensten van derden** — functies voor metadata, ondertitels en online bronnen contacteren de diensten onder [Contentbronnen en integraties](#contentbronnen-en-integraties) alleen wanneer je ze gebruikt.

## Ontwikkelingsactiviteit

[![Ontwikkelingsactiviteit](../assets/dev-activity.svg)](https://github.com/hajisensai/Fushi/commits/develop)

Het dagelijkse werk landt op `develop`; `main` ontvangt alleen release-merges. De grafiek wordt hier op `main` getoond maar is gegenereerd vanuit `develop`, zodat ze de werkelijke ontwikkeling weergeeft in plaats van merge-verkeer.

De drie banen zijn de updatekanalen die de app zelf aanbiedt, en elke baan is geschaald naar haar eigen piek — debug-builds overtreffen stabiele releases met twee ordes van grootte, dus een gedeelde schaal zou de andere twee banen platdrukken tot niets.

| Baan | Wat er wordt geteld | Hoe je het krijgt |
|---|---|---|
| **Debug (doorlopend)** | Geslaagde push-builds van [release.yml](../../.github/workflows/release.yml) | Doorlopende prerelease, bij elke push opnieuw gepubliceerd |
| **Bèta** | `v<version>-beta.<seq>`-prereleases | Handmatig gestarte testbuild |
| **Stabiel** | `v<version>`-releases | Nieuwste release |

> De grafiek hierboven wordt binnen deze repository gegenereerd (geen externe dienst) en dagelijks ververst door de workflow [Update Dev Activity Chart](../../.github/workflows/dev-activity.yml).

## Sterrengeschiedenis

[![GitHub stars](https://img.shields.io/github/stars/hajisensai/Fushi?style=flat&logo=github&label=Stars)](https://github.com/hajisensai/Fushi/stargazers)

[![Sterrengeschiedenis](../assets/star-history.svg)](https://github.com/hajisensai/Fushi/stargazers)

> De grafiek hierboven wordt binnen deze repository gegenereerd (geen externe dienst) en dagelijks ververst door de workflow [Update Star History](../../.github/workflows/star-history.yml).

## Dankbetuigingen

Fushi bouwt voort op de volgende projecten en het volgende ecosysteem:

### Leermiddelen en voorlopers

| Project | Beschrijving |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Japanse immersieve leertool |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS-Japanse lezer; referentie voor de reader-paginamotor |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Native Japanse lezer voor Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++-woordenboekengine |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Oplossing voor audioboeksynchronisatie |
| [Tsubasa](https://github.com/SonicSandbox/Tsubasa-sync) | Algoritme voor het uitlijnen van ondertiteltiming op een referentie (GPL-3.0); basis voor het automatisch uitlijnen van gedownloade ondertitels op ingebedde sporen |
| [Yomitan](https://github.com/yomidevs/yomitan) | Referentie voor woordenboekformaat, transformatietabellen en opzoekervaring |
| [Lapis](https://github.com/donkuri/lapis) | Anki-notitietype |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Android-integratie voor kaarten maken |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Referentie voor lokale audio en AnkiDroid-interactie |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Referentie voor lezer, statistieken en sync-compatibiliteit |
| [media_kit](https://github.com/media-kit/media-kit) | Flutter-videoweergaveframework (libmpv-kern) |
| [Niratan](https://github.com/W1ght/Niratan) | Immersieve taalleersuite voor macOS |

### Engines en native componenten

| Project | Beschrijving |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | Tekst-hookengine voor galgames (meegeleverde DLL's, geladen door de injector) |
| [MinHook](https://github.com/TsudaKageyu/minhook) | Inline-hookbibliotheek die de galgame-injector gebruikt |
| [libtorrent](https://github.com/arvidn/libtorrent) | Ingebouwde torrent-downloadengine |
| [mpv](https://github.com/mpv-player/mpv) | libmpv-afspeelkern achter media_kit |
| [FFmpeg](https://ffmpeg.org) | Media-analyse, knippen en audio-extractie |
| [libplacebo](https://github.com/haasn/libplacebo) | GPU-videoshaders en HDR-tonemapping |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | WebView-engine die de EPUB-lezer rendert |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | Inferentie op het apparaat voor spraakherkenning en OCR |
| [iroh](https://github.com/n0-computer/iroh) | P2P-tunnel voor externe Fushi Interconnect-verbindingen |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | Afhankelijkheden van de woordenboekengine |

### Modellen op het apparaat

| Project | Beschrijving |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Zipformer-spraakherkenningsmodelpakketten en VAD-builds |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | Japans spraakherkenningsmodel |
| [Parakeet TDT-CTC 0.6B ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) | Japans spraakherkenningsmodel |
| [Kitsune](https://huggingface.co/subthx/kitsune-onnx) | Japans spraakherkenningsmodel (CC BY-NC 4.0, gedownload uit de Hugging Face-repository) |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | Meertalig CTC-spraakherkenningsmodel |
| [Silero VAD](https://github.com/snakers4/silero-vad) | Model voor detectie van spraakactiviteit |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | Model voor detectie van manga-tekst en tekstballonnen |
| [manga-panel-detector-yolo26n](https://huggingface.co/leoxs22/manga-panel-detector-yolo26n) | Model voor het detecteren van manga-panelen, getraind op [Manga109-s](http://www.manga109.org/en/download_s.html) |
| [PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR) small det / rec · [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga) | Detectie en herkenning van tekstregels; de op manga afgestemde rec (getraind met [Manga109-s](http://www.manga109.org/en/download_s.html) en [AnimeText](https://huggingface.co/datasets/deepghs/AnimeText)) drijft het lokale CTC-OCR-model per kolom aan |

> Het model voor het detecteren van manga-panelen en PP-OCRv6_manga zijn getraind met de Manga109-s-dataset (Matsui et al. 2017; Aizawa et al. 2020), waarvan de voorwaarden vereisen dat dit gebruik van de dataset duidelijk wordt vermeld. PP-OCRv6_manga (Apache-2.0) is bovendien getraind met de AnimeText-dataset, die onder CC BY-NC-SA 4.0 is gelicentieerd; de app downloadt dat model uit de Hugging Face-repository en verspreidt het niet zelf.

### Contentbronnen en integraties

| Project | Beschrijving |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | Ecosysteem van manga-bronextensies |
| [Aniyomi](https://github.com/aniyomiorg/aniyomi) | Ecosysteem van anime-bronextensies (extensions-lib 14–16, dezelfde runtime) |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | Manga-extensieruntime voor desktop (meegeleverd, MPL-2.0) |
| [Mangayomi](https://github.com/kodjodevf/mangayomi) | Referentie voor de aanpassing van Mihon- / Aniyomi-extensies |
| [LNReader](https://github.com/LNReader/lnreader-plugins) | Ecosysteem van bronplugins voor light novels |
| [Jellyfin](https://jellyfin.org) · [Emby](https://emby.media) · [Plex](https://www.plex.tv) | Mediaservers die vanuit de videobibliotheek doorzocht kunnen worden |
| [asbplayer](https://github.com/asbplayer/asbplayer) | Referentie voor de streaming-ondertitelbrug van de browserextensie |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | Architectuurreferentie voor anime-identificatie en -scraping |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | Referentie voor de informatiearchitectuur van de galgamebibliotheek |
| [AniDB](https://anidb.net) | Identiteit van anime, afleveringen en bestanden |
| [MyAnimeList](https://myanimelist.net) (via [Jikan](https://jikan.moe)) | Anime-metadata |
| [TMDB](https://www.themoviedb.org) | Aanvullende metadata en beeldmateriaal |
| [VNDB](https://vndb.org) | Metadata van visual novels |
| [Jimaku](https://jimaku.cc) | Bron voor Japanse ondertitels |
| [OpenSubtitles](https://www.opensubtitles.com) | Ondertitelbron |

> Deze applicatie maakt gebruik van TMDB en de TMDB API's maar is niet goedgekeurd, gecertificeerd of anderszins geautoriseerd door TMDB.

## Licentie

Gedistribueerd onder de GNU General Public License v3.0. Zie [LICENSE](../../LICENSE) voor details.

## Beheerder

Fushi wordt onderhouden door [hajisensai](https://github.com/hajisensai). Website: [fushi.moe](https://fushi.moe). Contact: [contact@fushi.moe](mailto:contact@fushi.moe).

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | **Nederlands** | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
