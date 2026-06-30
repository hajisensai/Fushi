# Guide d'utilisation de hibiki

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | **Français** | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> Le guide en chinois simplifié est hébergé sur Feishu (lien ci-dessus). Le guide en anglais est également disponible [sur GitHub](https://github.com/hajisensai/hibiki/blob/main/docs/user-guide.md).

## Introduction

Il s'agit d'un logiciel gratuit pour Android / Windows (iOS / macOS prévus) : une application open source multiplateforme révolutionnaire qui combine la lecture de romans, la lecture de livres audio, la lecture de vidéos et la recherche dans des dictionnaires.

### URL du projet

https://github.com/hajisensai/hibiki

En développement actif : vos retours seront traités rapidement. Les rapports de bugs et les demandes de fonctionnalités sont les bienvenus. Si Hibiki vous est utile, n'hésitez pas à le partager ou à laisser une ⭐ sur le dépôt.

### Téléchargement

https://github.com/hajisensai/hibiki/releases/latest

Android : choisissez **arm64**. Windows : choisissez le fichier **.exe**.

## Tutoriel de configuration

### 1. Importer les dictionnaires recommandés et l'audio local (facultatif)

[OneDrive](https://zfile.kanochi.cn/dl/Public/%E6%9D%82%E9%A1%B9/hibiki-backup-2026-06-29.hibiki.zip) / [Google Drive](https://drive.google.com/file/d/1JYzv6dXB5sDPQBxttFLJzlmN3XTTo79S/view?usp=sharing)

Dans l'application : Paramètres -> Synchronisation et sauvegarde -> appuyez sur **Importer une sauvegarde**.

**Remarque : importer une sauvegarde effacera les données locales. Ce flux sera amélioré dans une future mise à jour.**

![Écran d'importation de sauvegarde](static-assets/user-guide/import-backup.png)

### 2. Télécharger et configurer Anki depuis le site officiel d'Anki

Anki — dont le nom vient de 暗記 (あんき) — est le [système de répétition espacée (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) le plus utilisé au monde, et un outil très important.

Liens : [Site officiel d'Anki](https://apps.ankiweb.net/) · [Manuel (chinois)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(chinois)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

*[Image : illustration / légende]*

Vous pouvez confier à Anki n'importe quel contenu que vous souhaitez mémoriser, et il vous permet d'obtenir la meilleure rétention avec le moins de temps d'étude.

Anki intègre [FSRS](https://github.com/open-spaced-repetition/fsrs4anki), l'un des meilleurs algorithmes de répétition espacée au monde.

**MAIS !!!** L'algorithme par défaut d'Anki est SM2, un algorithme vieux de plus de 30 ans peu performant. Veillez à passer l'algorithme utilisé par Anki à **FSRS**.

#### Anki

##### Android

1. Installez et ouvrez Anki.
2. Revenez à hibiki, allez dans Paramètres -> Création de cartes.
3. Appuyez sur **Actualiser les paquets et les types de notes** (repère « 1 » sur l'image) ; hibiki demandera une autorisation : appuyez sur Autoriser.
4. Appuyez sur **Créer un paquet Lapis** (repère « 2 » sur l'image).
5. S'il n'y a aucun avertissement ni erreur en rouge, la configuration a réussi.

![Configuration d'Anki sous Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Installez et ouvrez Anki.
2. Cliquez sur **Outils (Tools)** en haut à gauche.

![Menu Outils d'Anki sous Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Collez le code de module complémentaire Anki ci-dessous pour l'installer : `2055492159`
4. Revenez à hibiki, allez dans Paramètres -> Création de cartes.
5. Appuyez sur **Actualiser les paquets et les types de notes** (repère « 1 »).
6. Appuyez sur **Créer un paquet Lapis** (repère « 2 »).
7. S'il n'y a aucun avertissement ni erreur en rouge, la configuration a réussi.

![Configuration d'Anki sous Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Parcourez les options dans les Paramètres pour voir si vous souhaitez ajuster quelque chose. (Facultatif)

## Remerciements

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
