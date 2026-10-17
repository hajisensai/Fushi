<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="logo Fushi" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | **Français** | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Télécharger la dernière version](https://img.shields.io/badge/%E2%AC%87%20T%C3%A9l%C3%A9charger%20la%20derni%C3%A8re%20version-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Rejoindre le Discord](https://img.shields.io/badge/Rejoindre%20le%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Prise en charge des plateformes

| Plateforme | État | Remarques |
|---|---|---|
| Android | ✅ | Android 7.0 (API 24) ou version ultérieure |
| Windows | ✅ | Le hooking du texte et de la voix des galgames n'est disponible que sous Windows |
| macOS | ✅ | Apple Silicon uniquement ; les Mac Intel ne sont pas pris en charge |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | Pas de découverte, de sources en ligne ni de centre de téléchargement (règles de l'App Store) |
| Linux | 🔧 À compiler depuis les sources | Pas encore de version précompilée ; le lecteur EPUB nécessite WPE WebKit |
| Fushi Server | 🧪 Bêta ([fushi-server](https://github.com/hajisensai/fushi-server/releases)) | Hôte sans interface pour Linux / Windows / macOS avec interface web — voir [packages/fushi_server](../../packages/fushi_server/README.md) |

**Système de design** — toutes les plateformes utilisent par défaut **Material 3 Expressive** ; un système de design **Cupertino** (style Apple) peut être sélectionné dans *Paramètres › Apparence › Système de design* ; avec Cupertino, l'arrière-plan de la fenêtre utilise Mica sous Windows 11 et vibrancy sous macOS (sauf si le réglage système de réduction de la transparence ou de contraste élevé est activé).

> Les langues disponibles pour la recherche dans les dictionnaires sont déterminées par les dictionnaires importés et les tables de transformation de Yomitan, indépendamment de la langue de l'interface. Les mises à jour iOS arrivent via TestFlight quelques jours après celles des autres plateformes.

### Langues d'interface (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Installation

Téléchargez la dernière version depuis le [site web de Fushi](https://fushi.moe/) : l'APK Android, l'installateur Windows et les builds macOS (Apple Silicon uniquement ; les Mac Intel ne sont pas pris en charge) sont disponibles ; iOS s'installe via [TestFlight](https://testflight.apple.com/join/j88d69jx). Linux n'a pas encore de version précompilée de l'application ; compilez-la depuis les sources. Fushi Server, le serveur sans interface, est publié séparément sur [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server/releases).

> Nécessite Android 7.0 (API 24) ou supérieur.

## Compilation

Préparation en une seule commande (`flutter pub get` + application des correctifs), puis compilez :

```bash
# Depuis la racine du dépôt
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Bureau
flutter build windows --release
flutter build macos --release
flutter build linux --release
# iOS
flutter build ipa --release

# Serveur sans interface (depuis packages/fushi_server ; utilisez `dart build cli`, pas `dart compile exe`)
dart build cli
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` regroupent `flutter pub get` et `ci/apply-patches.sh` en une seule commande. Ce projet est verrouillé sur Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`) ; les versions antérieures de Flutter ne peuvent pas le compiler, car Material et Cupertino sont consommés sous forme des paquets `material_ui` / `cupertino_ui`. Certaines dépendances upstream sont incluses dans `third_party/` ou corrigées par `ci/apply-patches.sh` ; consultez [docs/agent/build.md](../agent/build.md) pour plus de détails, y compris les dépendances de compilation du bureau Linux.

<details>
<summary><b>Pile technique</b></summary>

| Couche | Technologie |
|---|---|
| Framework | Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`), Riverpod |
| Plateformes | Android / Windows / macOS / iOS / Linux, plus un serveur sans interface |
| UI | `material_ui` (Material 3 Expressive) / `cupertino_ui` (Cupertino) |
| Lecteur | Moteur de pagination WebView (dérivé de la famille Hoshi Reader) |
| Vidéo | media_kit (libmpv core) + libplacebo |
| Stockage | Drift (SQLite, WAL) + fushidicts (moteur de dictionnaires FFI en C++) |
| TALN | Tables de transformation Yomitan (lemmatisation multilingue) + kana_kit (conversion de kana) ; tokenisation via fushidicts FFI |
| IA embarquée | ONNX Runtime pour la reconnaissance vocale (génération de sous-titres) et l'OCR de manga ; les algorithmes se trouvent dans [fushi-subtitles](https://github.com/hajisensai/fushi-subtitles) |
| Téléchargements | libtorrent 2.x via un pont FFI en C-ABI (qBittorrent externe en secours) |
| Synchronisation | Backends cloud + Fushi Interconnect (LAN, adresses distantes et tunnel P2P iroh) |
| Moteur partagé | `fushi_engine` : cœur en Dart pur partagé par l'application et Fushi Server |
| Création de cartes | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 langues) |

</details>

<details>
<summary><b>Structure du projet</b></summary>

```
Fushi/                      # Racine du dépôt (espace de travail Melos : fushi_workspace)
├── fushi/                  # Répertoire principal de l'application Flutter
│   ├── lib/
│   │   ├── i18n/            # Internationalisation (17 langues, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pages (pages de bibliothèque, lecteur, lecteur vidéo, paramètres, etc.)
│   │   │   ├── reader/      # Scripts JS/CSS du WebView du lecteur
│   │   │   ├── media/       # Livres, mangas, vidéos, livres audio, sources en ligne
│   │   │   ├── lookup/      # Fenêtres et superpositions de recherche dans les dictionnaires
│   │   │   ├── mining/      # Création de cartes (incl. mining de galgames)
│   │   │   ├── sync/        # Synchronisation cloud, Interconnect, serveurs multimédias
│   │   │   └── models/      # Modèles de données et gestion d'état (AppModel)
│   │   └── main.dart
│   └── android/             # Projet Android
├── packages/                # Paquets Dart
│   ├── fushi_core/          #   Schéma de base de données, préférences
│   ├── fushi_engine/        #   Moteur en Dart pur partagé avec le serveur
│   ├── fushi_server/        #   CLI du serveur sans interface + interface web
│   ├── fushi_cli/           #   Client en ligne de commande pour le bureau
│   ├── fushi_dictionary/    #   Bindings du moteur de dictionnaires et importeurs
│   ├── fushi_anki/ · fushi_audio/ · fushi_platform/ · fushi_srs/
│   ├── fushi_torrent/ · fushi_p2p/   # Bindings FFI libtorrent / iroh
│   └── …                    #   Forks inclus (inappwebview Windows/Linux, gamepads)
├── native/                  # Sources natives : fushidicts, fushi_torrent, fushi_p2p (Rust), galgame_hook, …
├── services/                # Collecteur de journaux et backends du classement (déployés séparément)
├── tools/browser-extension/ # Extension de navigateur pour la recherche dans les dictionnaires
├── third_party/             # Paquets corrigés inclus (dependency_overrides)
├── ci/                      # Correctifs de compilation et scripts de CI
├── tool/                    # Scripts bootstrap / setup_worktree / suivi des bugs
└── docs/                    # Documentation de développement (incl. manuel d'exploitation docs/agent/)
```

</details>

L'import de vidéos permet un regroupement par œuvre ou par dossier. Consultez le [flux de travail vidéo](../specs/2026-09-07-video-library-workflow.md) et les [métadonnées MAL/TMDB avec hachage de fichiers AniDB](../specs/2026-09-07-mal-tmdb-anidb-hash.md) pour la correspondance et les tâches en arrière-plan.

La [configuration facultative des services en ligne](../specs/2026-09-07-online-services-setup.md) explique les identités d'application incluses, les identifiants personnels et le rappel de configuration vidéo qui peut être ignoré.

## Confidentialité et données

Fushi stocke les livres importés, les dictionnaires, les polices, les données des livres audio, les vidéos, la progression de lecture, les surlignages, les statistiques et les paramètres dans le stockage local de l'application.

- **Synchronisation** — Google Drive / OneDrive / Dropbox utilisent une connexion OAuth ; WebDAV / FTP / SFTP / Fushi Server utilisent l'adresse du serveur et les identifiants que vous fournissez. Fushi Interconnect connecte directement les appareils appairés (LAN, IPv6, réseaux superposés ou adresses publiques) et, lorsqu'aucune route directe ne fonctionne, bascule sur un tunnel P2P iroh de bout en bout ; les liens d'appairage demandent toujours une confirmation.
- **Anki** — la création de cartes communique avec AnkiDroid ou avec l'adresse AnkiConnect que vous configurez.
- **Statistiques d'utilisation** — une fois par jour, les builds de bureau et Android envoient à fushi.moe un identifiant d'installation aléatoire, la version de l'application, la plateforme et le canal de mise à jour afin de compter les utilisateurs actifs ; aucun compte, bibliothèque ni donnée de lecture n'est inclus et les adresses IP ne sont pas conservées. Désactivez-les avec *Partager les statistiques d’utilisation* dans les paramètres de mise à jour. Les builds iOS ne les envoient pas.
- **Uniquement à votre demande** — l'envoi des journaux (après une demande de consentement unique), les retours dans l'application et le classement (désactivé par défaut ; il n'envoie les titres de votre bibliothèque et votre progression qu'après votre accord).
- **OCR de manga** — le moteur par défaut est Google Lens, qui envoie l'image de la page à Google ; passez au modèle embarqué ou à l'OCR du système dans les paramètres pour garder les images en local.
- **Fonctions d'IA** — les requêtes ne vont qu'au fournisseur de LLM que vous configurez et affectez à une fonction ; sans fournisseur affecté, rien n'est envoyé.
- **Services tiers** — les fonctions de métadonnées, de sous-titres et de sources en ligne ne contactent les services listés sous [Sources de contenu et intégrations](#sources-de-contenu-et-intégrations) que lorsque vous les utilisez.

## Activité de développement

[![Activité de développement](../assets/dev-activity.svg)](https://github.com/hajisensai/Fushi/commits/develop)

Le travail quotidien arrive sur `develop` ; `main` ne reçoit que les fusions de publication. Le graphique est affiché ici sur `main` mais il est généré à partir de `develop`, il reflète donc le développement réel plutôt que le trafic de fusions.

Les trois couloirs correspondent aux canaux de mise à jour proposés par l'application elle-même, et chacun est mis à l'échelle sur son propre pic : les builds debug surpassent les versions stables de deux ordres de grandeur, si bien qu'une échelle commune réduirait les deux autres couloirs à presque rien.

| Couloir | Ce qui est compté | Comment l'obtenir |
|---|---|---|
| **Debug (continu)** | Builds réussis à chaque push de [release.yml](../../.github/workflows/release.yml) | Préversion continue, republiée à chaque push |
| **Bêta** | Préversions `v<version>-beta.<seq>` | Build de test lancé manuellement |
| **Stable** | Versions `v<version>` | Dernière version |

> Le graphique ci-dessus est généré dans ce dépôt (sans service tiers) et actualisé chaque jour par le workflow [Update Dev Activity Chart](../../.github/workflows/dev-activity.yml).

## Historique des étoiles

[![GitHub stars](https://img.shields.io/github/stars/hajisensai/Fushi?style=flat&logo=github&label=Stars)](https://github.com/hajisensai/Fushi/stargazers)

[![Star History](../assets/star-history.svg)](https://github.com/hajisensai/Fushi/stargazers)

> Le graphique ci-dessus est généré dans ce dépôt (sans service tiers) et actualisé chaque jour par le workflow [Update Star History](../../.github/workflows/star-history.yml).

## Remerciements

Fushi s'appuie sur les projets et l'écosystème suivants :

### Outils d'apprentissage et travaux antérieurs

| Projet | Description |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Outil d'apprentissage immersif du japonais |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Lecteur de japonais pour iOS ; référence du moteur de pagination du lecteur |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Lecteur de japonais natif pour Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Moteur de dictionnaires en C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solution de synchronisation des livres audio |
| [Tsubasa](https://github.com/SonicSandbox/Tsubasa-sync) | Algorithme d'alignement temporel des sous-titres sur une référence (GPL-3.0) ; base de l'alignement automatique des sous-titres téléchargés sur les pistes intégrées |
| [Yomitan](https://github.com/yomidevs/yomitan) | Référence pour le format de dictionnaire, les tables de transformation et l'expérience de recherche |
| [Lapis](https://github.com/donkuri/lapis) | Type de note Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Intégration de la création de cartes sur Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Référence pour l'audio local et l'interaction avec AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Référence de compatibilité pour le lecteur, les statistiques et la synchronisation |
| [media_kit](https://github.com/media-kit/media-kit) | Framework de lecture vidéo pour Flutter (cœur libmpv) |
| [Niratan](https://github.com/W1ght/Niratan) | Suite d'apprentissage immersif des langues pour macOS |

### Moteurs et composants natifs

| Projet | Description |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | Moteur de hooking de texte pour galgames (DLL incluses, chargées par l'injecteur) |
| [MinHook](https://github.com/TsudaKageyu/minhook) | Bibliothèque de hooking inline utilisée par l'injecteur de galgames |
| [libtorrent](https://github.com/arvidn/libtorrent) | Moteur de téléchargement torrent intégré |
| [mpv](https://github.com/mpv-player/mpv) | Cœur de lecture libmpv derrière media_kit |
| [FFmpeg](https://ffmpeg.org) | Analyse des médias, découpage et extraction audio |
| [libplacebo](https://github.com/haasn/libplacebo) | Shaders vidéo GPU et tone mapping HDR |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | Moteur WebView qui affiche le lecteur EPUB |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | Inférence embarquée pour la reconnaissance vocale et l'OCR |
| [iroh](https://github.com/n0-computer/iroh) | Tunnel P2P pour les connexions distantes de Fushi Interconnect |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | Dépendances du moteur de dictionnaires |

### Modèles embarqués

| Projet | Description |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Paquets de modèles Zipformer de reconnaissance vocale et builds VAD |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | Modèle de reconnaissance vocale en japonais |
| [Parakeet TDT-CTC 0.6B ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) | Modèle de reconnaissance vocale en japonais |
| [Kitsune](https://huggingface.co/subthx/kitsune-onnx) | Modèle de reconnaissance vocale en japonais (CC BY-NC 4.0, téléchargé depuis son dépôt Hugging Face) |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | Modèle multilingue de reconnaissance vocale CTC |
| [Silero VAD](https://github.com/snakers4/silero-vad) | Modèle de détection d'activité vocale |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | Modèle de détection du texte et des bulles de manga |
| [manga-panel-detector-yolo26n](https://huggingface.co/leoxs22/manga-panel-detector-yolo26n) | Modèle de détection des cases de manga, entraîné sur [Manga109-s](http://www.manga109.org/en/download_s.html) |
| [PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR) small det / rec · [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga) | Détection et reconnaissance de lignes de texte ; le rec adapté au manga (entraîné avec [Manga109-s](http://www.manga109.org/en/download_s.html) et [AnimeText](https://huggingface.co/datasets/deepghs/AnimeText)) alimente le modèle d'OCR local CTC par colonne |

> Le modèle de détection des cases de manga et PP-OCRv6_manga sont entraînés avec le jeu de données Manga109-s (Matsui et al. 2017 ; Aizawa et al. 2020), dont les conditions exigent d'indiquer clairement cette utilisation du jeu de données. PP-OCRv6_manga (Apache-2.0) est en outre entraîné avec le jeu de données AnimeText, placé sous licence CC BY-NC-SA 4.0 ; l'application télécharge ce modèle depuis son dépôt Hugging Face et ne le redistribue pas.

### Sources de contenu et intégrations

| Projet | Description |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | Écosystème d'extensions de sources de manga |
| [Aniyomi](https://github.com/aniyomiorg/aniyomi) | Écosystème d'extensions de sources d'anime (extensions-lib 14–16, hébergées par le même runtime) |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | Runtime d'extensions de manga pour le bureau (inclus, MPL-2.0) |
| [Mangayomi](https://github.com/kodjodevf/mangayomi) | Référence d'adaptation des extensions Mihon / Aniyomi |
| [LNReader](https://github.com/LNReader/lnreader-plugins) | Écosystème de plugins de sources de romans légers |
| [Jellyfin](https://jellyfin.org) · [Emby](https://emby.media) · [Plex](https://www.plex.tv) | Serveurs multimédias consultables depuis la bibliothèque vidéo |
| [asbplayer](https://github.com/asbplayer/asbplayer) | Référence du pont de sous-titres en streaming pour l'extension de navigateur |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | Référence d'architecture pour l'identification et le scraping d'anime |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | Référence d'architecture de l'information de la bibliothèque de galgames |
| [AniDB](https://anidb.net) | Identité des animes, épisodes et fichiers |
| [MyAnimeList](https://myanimelist.net) (via [Jikan](https://jikan.moe)) | Métadonnées d'anime |
| [TMDB](https://www.themoviedb.org) | Métadonnées et visuels complémentaires |
| [VNDB](https://vndb.org) | Métadonnées de visual novels |
| [Jimaku](https://jimaku.cc) | Source de sous-titres japonais |
| [OpenSubtitles](https://www.opensubtitles.com) | Source de sous-titres |

> Cette application utilise TMDB et les API TMDB mais n'est pas approuvée, certifiée ou autrement autorisée par TMDB.

## Licence

Distribué sous la licence publique générale GNU v3.0. Voir [LICENSE](../../LICENSE) pour plus de détails.

## Mainteneur

Fushi est maintenu par [hajisensai](https://github.com/hajisensai). Site web : [fushi.moe](https://fushi.moe). Contact : [contact@fushi.moe](mailto:contact@fushi.moe).

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | **Français** | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
