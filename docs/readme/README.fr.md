<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center"><b>Lisez un livre, et faites de chaque mot inconnu le vôtre.</b></p>
<p align="center">Lecteur immersif multiplateforme et multilingue — lecture EPUB · recherche de mots par sélection · création de cartes Anki · synchronisation de livres audio · recherche de mots dans les sous-titres vidéo</p>

<p align="center">
  <img src="https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white" alt="Android">
  <img src="https://img.shields.io/badge/iOS-000000?logo=apple&logoColor=white" alt="iOS">
  <img src="https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white" alt="macOS">
  <img src="https://img.shields.io/badge/Windows-0078D6?logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/Linux-FCC624?logo=linux&logoColor=black" alt="Linux">
  &nbsp;·&nbsp;
  <img src="https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/license-GPLv3-blue" alt="GPLv3">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>📖 Page d'accueil du projet (GitHub Pages)</b></a>
</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <b>Français</b> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Introduction

**hibiki** est un lecteur multiplateforme d'apprentissage immersif des langues. Dans le corps d'un EPUB, **appuyez pour chercher un mot, sélectionnez pour analyser**, et transformez un mot inconnu en carte Anki en un clic ; synchronisez l'audio d'un livre audio avec le texte phrase par phrase en surlignage ; et cherchez même des mots et créez des cartes directement dans les sous-titres vidéo. Un seul outil pour couvrir vos trois formes d'entrée immersive : « lire · écouter · regarder ».

La recherche dans le dictionnaire couvre **toutes les langues de transformation** de [Yomitan](https://github.com/yomidevs/yomitan) (déflexion + normalisation du texte avant recherche), l'interface est localisée en **17 langues**, et l'application prend en charge les cinq plateformes **Android / iOS / macOS / Windows / Linux**.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-home.png" alt="Bibliothèque" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-dictionaries.png" alt="Recherche de mots" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-settings.png" alt="Paramètres et thèmes" width="300">
</p>
<p align="center"><sub>Bibliothèque · Recherche de mots · Paramètres et thèmes</sub></p>

---

## Points forts

### 📖 Lecture EPUB, recherche en un appui

Lecteur EPUB rendu en WebView (moteur de pagination dérivé de [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) : appuyez sur n'importe quel mot pour le chercher instantanément, sélectionnez une zone pour l'analyser sur-le-champ. Deux modes, défilement continu et pagination, polices et thèmes personnalisables (clair / sombre / noir pur / personnalisé), furigana, statistiques de lecture et signets, tout y est.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-reader.png" alt="Lecture verticale · Furigana · Synchronisation de livre audio" width="300">
</p>
<p align="center"><sub>Texte vertical · Furigana · Surlignage par sélection · Barre de contrôle de synchronisation du livre audio en bas</sub></p>

### 🔍 Recherche par sélection, couvrant toutes les langues de transformation de Yomitan

Importez des dictionnaires aux formats **Yomitan** (anciennement Yomichan) / **ABBYY Lingvo (DSL)** / **MDict (MDX)** / **Migaku**. Lemmatisation multilingue (tables de transformation Yomitan) + normalisation du texte avant recherche (casse / diacritiques / harakat arabe), pilotée par point de code, sans avoir à changer de langue. Recherche parallèle dans plusieurs dictionnaires, priorité et activation/désactivation des sous-sources, marquage de l'accent tonal et fréquence des mots, le tout dans une seule fenêtre contextuelle.

### 🎴 Création de cartes Anki en un clic

Une fois un mot inconnu trouvé, exportez-le en une étape vers [AnkiDroid](https://github.com/ankidroid/Anki-Android) et AnkiConnect. Schéma de type de note [Lapis](https://github.com/donkuri/lapis) intégré (vendoré 1.7.0), permettant de créer modèles de cartes et paquets directement dans l'application ; remplissage automatique des phrases de contexte, prise en charge de l'enregistrement audio et du recadrage de captures d'écran, profils d'export multiples (Profile), mappage de champs personnalisé et actions rapides pour créer une carte en un geste.

### 🎧 Synchronisation de livres audio (Sasayaki)

Prise en charge des sous-titres SRT / LRC / VTT / ASS, avec alignement automatique du texte des sous-titres sur le corps de l'EPUB. À la lecture, **surlignage en lecture suivie et changement de page synchronisé avec l'audio**, accompagnés d'une barre de contrôle de lecture (progression, navigation, vitesse) : à l'écoute, le texte s'illumine phrase par phrase — la barre de contrôle en bas de la capture d'écran de lecture en haut de cette page illustre cette fonctionnalité.

### 🎬 Recherche de mots dans les sous-titres vidéo

Lecteur vidéo intégré basé sur media_kit / libmpv, prenant en charge les sous-titres intégrés / externes. Pendant la lecture d'une vidéo, **cherchez des mots et créez des cartes directement sur les sous-titres**, intégrant ainsi vos contenus vidéo à votre entrée immersive ; le temps de visionnage et le nombre de cartes créées sont également comptabilisés.

<!-- TODO-782: 待补视频播放器截图 -->
<p align="center"><sub>📹 Capture d'écran du lecteur vidéo à venir</sub></p>

### 🔗 Et plus encore

- **17 langues d'interface**, localisation sur toutes les plateformes
- **Interconnexion Hibiki** : synchronisation des livres / dictionnaires / livres audio / progression de lecture entre appareils
- **Profils multi-utilisateurs (Profile)**, basculement automatique par livre
- **Mode incognito** ; **recherche directe en partageant du texte** depuis d'autres applications

---

## Plateformes prises en charge

| Plateforme | Statut | Rendu / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| iOS | ✅ | Cupertino |
| Windows | ✅ | Material (`flutter_inappwebview_windows` forké pour le rendu EPUB) |
| macOS | ✅ | Material |
| Linux | ✅ | Material |

> Android 7.0 minimum (API 24). La langue de recherche dans le dictionnaire dépend des dictionnaires importés et des tables de transformation Yomitan, indépendamment de la langue de l'interface.

### Langues d'interface (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

---

## Installation et compilation

Préparation en une commande (`flutter pub get` + application des patchs), puis compilation :

```bash
# à la racine du dépôt
bash tool/bootstrap.sh          # Windows PowerShell : .\tool\bootstrap.ps1
                                # ou (Linux/macOS) : dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` regroupe en une seule commande ① `flutter pub get` et ② `ci/apply-patches.sh`. Le projet est verrouillé sur Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) ; certaines dépendances en amont sont vendorées sous `third_party/` ou corrigées par `ci/apply-patches.sh` — détails du mécanisme, compilation sur les cinq plateformes, liste des dépendances et patchs dans [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Vue d'ensemble de la stack technique</b></summary>

| Couche | Technologie |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Plateforme | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino adaptatif) |
| Lecteur | Moteur de pagination WebView (dérivé de [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Vidéo | media_kit / libmpv |
| Stockage | Drift (SQLite, WAL) + hoshidicts (moteur de dictionnaires C++ FFI) |
| NLP | Tables de transformation Yomitan (lemmatisation multilingue) + kana_kit (conversion des kana) ; la segmentation passe par hoshidicts FFI |
| Création de cartes | AnkiDroid API + AnkiConnect |
| Internationalisation | Slang (17 langues) |

</details>

<details>
<summary><b>Structure du projet</b></summary>

```
hibiki/                      # Racine du dépôt (workspace Melos : hibiki_workspace)
├── hibiki/                  # Répertoire principal de l'application Flutter
│   ├── lib/
│   │   ├── i18n/            # Internationalisation (17 langues, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pages (bibliothèque, lecteur, dictionnaire, paramètres, etc.)
│   │   │   ├── reader/      # Scripts JS/CSS de la WebView du lecteur
│   │   │   ├── media/       # Livres audio, analyse des sous-titres, reader source
│   │   │   └── models/      # Modèles de données et gestion d'état (AppModel)
│   │   └── main.dart
│   └── android/             # Projet Android (manifest, hoshidicts natif)
├── packages/                # Packages internes + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── native/                  # Moteur de dictionnaires C++ hoshidicts (FFI)
├── third_party/             # Packages de patchs vendorés (référencés par dependency_overrides)
├── ci/                      # Patchs de build et scripts de tests d'intégration
├── tool/                    # Scripts bootstrap / i18n_sync, etc.
└── docs/                    # Documentation de développement (dont le manuel agent docs/agent/)
```

</details>

---

## Remerciements

| Projet | Description |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Outil d'apprentissage immersif du japonais |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Lecteur japonais Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Moteur de dictionnaires C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Lecteur japonais iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solution de synchronisation de livres audio |
| [Yomitan](https://github.com/yomidevs/yomitan) | Source des formats de dictionnaire et des tables de transformation |
| [Lapis](https://github.com/donkuri/lapis) | Type de note Anki |

## Licence

[GNU General Public License v3.0](../../LICENSE)

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <b>Français</b> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>
