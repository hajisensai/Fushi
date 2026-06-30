<div align="center">

# hibiki

<img src="../static-assets/hibiki-logo.png" alt="logo hibiki" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | **Français** | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[Guide d'utilisation](../user-guide.fr.md) | [Télécharger la dernière version](https://github.com/hajisensai/hibiki/releases)

> **Regardez ce que vous avez envie de regarder, et la langue vient toute seule.**

hibiki transforme les romans que vous lisez, les séries que vous suivez et les livres audio que vous écoutez en matière d'apprentissage : touchez n'importe quel mot inconnu pour le chercher, puis transformez-le en une carte Anki avec son contexte d'origine, d'un seul geste. Il ne vous fait pas mémoriser une liste de mots prédéfinie ; il vous aide simplement à saisir les mots que vous **lisez et entendez vraiment**.

La façon la plus efficace d'apprendre une langue, c'est de s'exposer massivement à du contenu réel, et non de mémoriser des mots isolés dans un manuel de vocabulaire. Mais l'« immersion » a toujours eu deux écueils : chercher un mot brise la concentration, et on l'oublie aussitôt qu'on détourne le regard. hibiki referme cette boucle :

📖 **Lire** : touchez un mot dans le lecteur EPUB pour le chercher, sans quitter la page en cours.<br>
🎧 **Écouter** : les livres audio surlignent phrase par phrase et tournent les pages automatiquement.<br>
🎬 **Regarder** : cherchez des mots et créez des cartes directement sur les sous-titres vidéo — suivre une série, c'est déjà de l'apprentissage.<br>
🃏 **Ancrer** : envoyez vers Anki n'importe quel mot cherché, dans n'importe quel contexte, et ne révisez que les mots que vous avez réellement rencontrés.

Tous les contextes partagent les mêmes dictionnaires, statistiques et processus de révision. Cela convient à n'importe quelle langue (japonais, anglais, …) et tout particulièrement aux apprenants en immersion qui croient au principe **beaucoup d'apport + uniquement des cartes faites soi-même**. Disponible pour Android et Windows (iOS et macOS prévus).

<table>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-bookshelf-en.png" alt="Bibliothèque" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-library-en.png" alt="Vidéothèque" width="100%"></td>
  </tr>
  <tr>
    <td colspan="2"><img src="../static-assets/screenshots/hibiki-readme-reader-vertical-lookup.png" alt="Lecture verticale sur ordinateur avec fenêtre de recherche" width="100%"></td>
  </tr>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-nested.png" alt="Recherche dans la vidéo (fenêtres imbriquées)" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-subtitle.png" alt="Recherche dans la vidéo (liste des sous-titres)" width="100%"></td>
  </tr>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-out-of-app-lookup-mobile.png" alt="Recherche par sélection de texte hors de l'application (mobile)" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-out-of-app-lookup-desktop.png" alt="Recherche par sélection de texte hors de l'application (ordinateur)" width="100%"></td>
  </tr>
</table>

**Démo de création de cartes Anki en un geste**

<video src="https://github.com/hajisensai/hibiki/raw/main/docs/static-assets/screenshots/hibiki-readme-anki-mining-demo.mp4" controls muted width="100%"></video>

> La vidéo ne s'affiche pas ? [Voir la démo de création de cartes en un clic ▶](https://github.com/hajisensai/hibiki/raw/main/docs/static-assets/screenshots/hibiki-readme-anki-mining-demo.mp4)

</div>

## Fonctionnalités

### Bibliothèque

- Importez des EPUB individuellement, en lot ou récursivement par dossier ; consultez la progression de lecture sur l'étagère.
- Organisez les livres avec des étagères personnalisées, le filtrage par étiquettes et le réagencement par glisser-déposer.
- Glissez-déposez des fichiers pour importer des livres, des sous-titres ou des vidéos (ordinateur).
- Associez automatiquement les fichiers de sous-titres / audio portant le même nom lors de l'import.

### Lecture

- Lisez en disposition verticale ou horizontale ; basculez entre les modes paginé et défilement continu.
- Personnalisez les thèmes (clair / sombre / noir pur / personnalisé), les polices, l'espacement des paragraphes et les commandes du lecteur.
- Annotations furigana (ふりがな).
- Échelle d'interface ajustable ; les commandes de la barre inférieure suivent l'échelle.
- Profils multi-utilisateurs (Profile), commutés automatiquement selon le livre.

### Recherche

- Importez des dictionnaires [Yomitan](https://github.com/yomidevs/yomitan) (anciennement Yomichan), ABBYY Lingvo (DSL), MDict (MDX) et Migaku.
- Touchez le texte dans le lecteur pour rechercher des mots, effectuez une recherche sur la page de dictionnaire ou partagez du texte depuis d'autres applications.
- Désinflexion couvrant **toutes les langues de transformation de Yomitan** + normalisation du texte avant recherche (casse / diacritiques / harakat arabe), pilotée par points de code sans changement de langue.
- Touchez les mots à l'intérieur des définitions pour une recherche récursive (fenêtres imbriquées).
- Requêtes parallèles sur plusieurs dictionnaires, priorité et activation des sous-sources, annotations d'accent tonal et de fréquence.
- Audio des mots en ligne et local.
- Injectez du CSS personnalisé.

### Surlignages et statistiques

- Ajoutez des surlignages en cinq couleurs pendant la lecture ; accédez à n'importe quel surlignage à tout moment.
- Statistiques de lecture : caractères lus, durée, vitesse de lecture — affichées en temps réel pendant la lecture.
- Statistiques vidéo : temps de visionnage, cartes créées et favoris.

### Création de cartes Anki

- Créez des cartes via [AnkiDroid](https://github.com/ankidroid/Anki-Android) ou AnkiConnect.
- Type de note [Lapis](https://github.com/donkuri/lapis) intégré (inclus en 1.7.0) ; créez des modèles de cartes et des paquets dans l'application en un seul geste.
- Remplissage automatique des phrases de contexte ; enregistrement audio et recadrage des captures d'écran.
- Plusieurs profils d'export (Profile) et mappage de champs personnalisé.
- Mots favoris ; les cartes créées et les favoris sont comptabilisés dans les statistiques.

### Synchronisation des livres audio (Sasayaki)

- Prise en charge des sous-titres SRT / LRC / VTT / ASS ; alignement automatique du texte des sous-titres sur le corps de l'EPUB.
- Surlignage des phrases en suivi et tournage de page automatique pendant la lecture.
- Vitesse de lecture, actions de navigation et commandes multimédias du système.
- « Lire à partir de cette phrase » avec continuation fluide entre les chapitres.

### Recherche dans les sous-titres vidéo

- Lecteur vidéo intégré basé sur [media_kit](https://github.com/media-kit/media-kit) (cœur libmpv).
- Sous-titres incrustés (pistes texte + graphiques) et externes ; import de listes de lecture .m3u8.
- Recherchez des mots et créez des cartes directement depuis les sous-titres pendant la lecture.
- Gestion de la vidéothèque, filtrage par étiquettes, regroupement en séries et opérations par lots.

### Synchronisation des données

- Sept backends de synchronisation : Google Drive, OneDrive, Dropbox, WebDAV, FTP, SFTP et Hibiki P2P.
- Synchronisez la progression de lecture, les statistiques et les livres.

### Plus

- **17 langues d'interface**, entièrement localisées sur toutes les plateformes.
- Partagez du texte depuis d'autres applications pour rechercher des mots directement.

## Prise en charge des plateformes

| Plateforme | État | Rendu / Interface |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material |

> Minimum Android 7.0 (API 24). Les langues disponibles pour la recherche dans les dictionnaires sont déterminées par les dictionnaires importés et les tables de transformation de Yomitan, indépendamment de la langue de l'interface.

### Langues d'interface (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Installation et compilation

Préparation en une seule commande (`flutter pub get` + application des correctifs), puis compilez :

```bash
# Depuis la racine du dépôt
bash tool/bootstrap.sh          # Windows PowerShell : .\tool\bootstrap.ps1

cd hibiki
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Bureau Windows
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` regroupent `flutter pub get` et `ci/apply-patches.sh` en une seule commande. Ce projet est verrouillé sur Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) ; certaines dépendances upstream sont incluses dans `third_party/` ou corrigées par `ci/apply-patches.sh` — voir [docs/agent/build.md](../agent/build.md) pour plus de détails.

<details>
<summary><b>Pile technique</b></summary>

| Couche | Technologie |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Plateformes | Android / Windows (Material Design 3) |
| Lecteur | Moteur de pagination WebView (dérivé de la famille Hoshi Reader) |
| Vidéo | media_kit (libmpv core) |
| Stockage | Drift (SQLite, WAL) + hoshidicts (moteur de dictionnaires FFI en C++) |
| TAL | Tables de transformation de Yomitan (lemmatisation multilingue) + kana_kit (conversion de kana) ; tokenisation via hoshidicts FFI |
| Création de cartes | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 langues) |

</details>

<details>
<summary><b>Structure du projet</b></summary>

```
hibiki/                      # Racine du dépôt (espace de travail Melos : hibiki_workspace)
├── hibiki/                  # Répertoire principal de l'application Flutter
│   ├── lib/
│   │   ├── i18n/            # Internationalisation (17 langues, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pages (bibliothèque, lecteur, dictionnaire, paramètres, etc.)
│   │   │   ├── reader/      # Scripts JS/CSS du WebView du lecteur
│   │   │   ├── media/       # Livres audio, analyse des sous-titres, source du lecteur
│   │   │   └── models/      # Modèles de données et gestion d'état (AppModel)
│   │   └── main.dart
│   └── android/             # Projet Android (manifest, hoshidicts natif)
├── packages/                # Paquets internes + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # Moteur de dictionnaires en C++ hoshidicts (FFI)
├── third_party/             # Paquets corrigés inclus (dependency_overrides)
├── ci/                      # Correctifs de compilation et scripts de tests d'intégration
├── tool/                    # Scripts bootstrap / i18n_sync et autres
└── docs/                    # Documentation de développement (incl. manuel d'exploitation docs/agent/)
```

</details>

## Confidentialité et données

hibiki stocke les livres importés, les dictionnaires, les polices, les données des livres audio, les vidéos, la progression de lecture, les surlignages, les statistiques et les paramètres dans le stockage local de l'application.

La synchronisation cloud (Google Drive / OneDrive / Dropbox) utilise des identifiants OAuth configurés par l'utilisateur ; WebDAV / FTP / SFTP utilise les adresses de serveur et les identifiants fournis par l'utilisateur ; Hibiki P2P se connecte directement via une adresse configurée par l'utilisateur. La création de cartes Anki communique avec AnkiDroid ou avec une adresse AnkiConnect configurée.

## Remerciements

hibiki s'appuie sur les projets et l'écosystème suivants :

| Projet | Description |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Outil d'apprentissage immersif du japonais |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Lecteur de japonais pour iOS ; référence du moteur de pagination du lecteur |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Lecteur de japonais natif pour Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Moteur de dictionnaires en C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solution de synchronisation des livres audio |
| [Yomitan](https://github.com/yomidevs/yomitan) | Référence de format de dictionnaire, tables de transformation et expérience de recherche |
| [Lapis](https://github.com/donkuri/lapis) | Type de note Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Intégration de création de cartes sur Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Référence d'audio local et d'interaction avec AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Référence de compatibilité de lecteur, statistiques et synchronisation |
| [media_kit](https://github.com/media-kit/media-kit) | Framework de lecture vidéo de Flutter (cœur libmpv) |

## Licence

Distribué sous la licence publique générale GNU v3.0. Voir [LICENSE](../../LICENSE) pour plus de détails.

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | **Français** | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
