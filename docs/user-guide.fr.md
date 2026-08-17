# Le guide Fushi que même Yui Hirasawa configure en 5 minutes

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | **Français** | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> Le guide en chinois simplifié est hébergé sur Feishu (lien ci-dessus). Le guide en anglais est également disponible [sur GitHub](https://github.com/hajisensai/Fushi/blob/main/docs/user-guide.md).

## Introduction

**Fushi — transformez vos marathons de lecture et de visionnage en input linguistique.**

Touchez n'importe quel mot pour le rechercher pendant que vous lisez des romans, regardez des animes ou écoutez des livres audio, et envoyez les nouveaux mots vers Anki accompagnés de la phrase dont ils proviennent.

Aucune liste de vocabulaire prédéfinie : vous ne révisez que les mots que vous avez réellement rencontrés. Fonctionne avec n'importe quelle langue.

- 📖 Lecture d'EPUB · toucher pour rechercher
- 🎧 Livres audio avec surlignage phrase par phrase
- 🎬 Recherche dans les sous-titres vidéo et création de cartes
- 🃏 Création de cartes Anki en un geste + statistiques de révision
- 📚 Lecture de manga · recherchez les mots directement sur la page grâce à l'OCR
- ⬇️ Téléchargements intégrés en un geste pour les animes et les mangas — ajoutés automatiquement à votre bibliothèque et lisibles pendant le téléchargement
- 🎮 Mining vocal de Galgame (Windows) · la réplique vocale d'origine est intégrée à la carte avec le texte

Plateformes : Android / Windows / macOS / iOS (Linux peut être compilé depuis les sources ; pas encore de paquets précompilés)

### URL du projet

https://github.com/hajisensai/Fushi

En développement actif : vos retours seront traités rapidement. Les rapports de bugs et les demandes de fonctionnalités sont les bienvenus. Si Fushi vous est utile, n'hésitez pas à le partager ou à laisser une ⭐ sur le dépôt.

### Téléchargement

https://github.com/hajisensai/Fushi/releases/latest

Choisissez le fichier correspondant à votre plateforme : **Android** — l'APK `arm64-v8a` (tous les téléphones de ces dernières années l'utilisent ; seuls les appareils plus anciens ont besoin d'`armeabi-v7a`, et les émulateurs utilisent `x86_64`) ; **Windows** — `windows-setup.exe` ; **macOS** — `macos.zip` ; **iOS** — `ios.ipa`. **Linux** n'a pas encore de paquet précompilé, il faut donc le compiler depuis les sources.

Les APK dont le nom commence par `bridge-` sont des passerelles de migration destinées aux **anciens utilisateurs de Hibiki** ; vous pouvez les ignorer.

## Tutoriel de configuration

### 1. Importer les dictionnaires recommandés (dictionnaires de mots + accent de hauteur + fréquence) et l'audio local (bases de données audio japonaise et anglaise) (Fortement recommandé pour les débutants!!! · facultatif)

[Google Drive](https://drive.google.com/file/d/1W0Civ-b9NAyCu6LpXYMcNI_wZJWB9xjp/view?usp=sharing) · [Téléchargement Cloudflare (9,5 Go)](https://dl.wrds.xyz/fushi-recommended-2026-08-14.fushi.zip)

Dans l'application : Paramètres -> Synchronisation et sauvegarde -> appuyez sur **Importer une sauvegarde**.

![Écran d'importation de sauvegarde](static-assets/user-guide/import-backup.png)

### 2. Télécharger et configurer Anki depuis le site officiel d'Anki

Anki — dont le nom vient de 暗記 (あんき) — est le [système de répétition espacée (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) le plus utilisé au monde, et un outil très important.

Liens : [Site officiel d'Anki](https://apps.ankiweb.net/) · [Manuel (chinois)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(chinois)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

![Page de téléchargement d'Anki](static-assets/user-guide/anki-download.png)

Vous pouvez confier à Anki n'importe quel contenu que vous souhaitez mémoriser, et il vous permet d'obtenir la meilleure rétention avec le moins de temps d'étude.

Anki intègre [FSRS](https://github.com/open-spaced-repetition/fsrs4anki), l'un des meilleurs algorithmes de répétition espacée au monde.

**MAIS !!!** L'algorithme par défaut d'Anki est SM2, un algorithme vieux de plus de 30 ans peu performant. Veillez à passer l'algorithme utilisé par Anki à **FSRS**.

#### Anki

##### Android

1. Installez et ouvrez Anki.
2. Revenez à Fushi, allez dans Paramètres -> Création de cartes.
3. Appuyez sur **Actualiser les paquets et les types de notes** (repère « 1 » sur l'image) ; Fushi demandera une autorisation : appuyez sur Autoriser.
4. Appuyez sur **Créer un paquet Lapis** (repère « 2 » sur l'image).
5. S'il n'y a aucun avertissement ni erreur en rouge, la configuration a réussi.

![Configuration d'Anki sous Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Installez et ouvrez Anki.
2. Cliquez sur **Outils (Tools)** en haut à gauche.

![Menu Outils d'Anki sous Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Collez le code de module complémentaire Anki ci-dessous pour l'installer : `2055492159`
4. Revenez à Fushi, allez dans Paramètres -> Création de cartes.
5. Appuyez sur **Actualiser les paquets et les types de notes** (repère « 1 »).
6. Appuyez sur **Créer un paquet Lapis** (repère « 2 »).
7. S'il n'y a aucun avertissement ni erreur en rouge, la configuration a réussi.

![Configuration d'Anki sous Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Parcourez les options dans les Paramètres pour voir si vous souhaitez ajuster quelque chose. (Facultatif)

Il est temps de commencer l'immersion.

## Fonctionnalités recommandées

### Rechercher des mots en dehors de l'application

**Android :** sélectionnez un mot, puis appuyez sur **Traduire** ou **Fushi** dans le menu de sélection.

**Windows :** sélectionnez un mot, puis appuyez sur **Ctrl+Alt+D** (le raccourci peut être modifié dans Paramètres -> Raccourcis).

### Recherche depuis le presse-papiers

Tout ce que vous copiez est recherché automatiquement. Deux modes d'affichage sont disponibles — le **panneau flottant** et la **fenêtre de texte transparente** — tous deux configurables dans Paramètres -> Recherche.

### Recherche dans le navigateur / mining des sous-titres en streaming (Netflix)

Installez l'extension de navigateur depuis la page d'accueil de Fushi.

## Remerciements

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
