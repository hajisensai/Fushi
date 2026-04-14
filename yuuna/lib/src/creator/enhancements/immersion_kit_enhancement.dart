import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:network_to_file_image/network_to_file_image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yuuna/creator.dart';
import 'package:yuuna/models.dart';
import 'package:http/http.dart' as http;
import 'package:yuuna/src/creator/enhancements/jp_conjugations.dart';
import 'package:yuuna/utils.dart';

/// An entity used to neatly return and organise results fetched from
/// ImmersionKit.
class ImmersionKitResult {
  /// Define a result with the given parameters.
  ImmersionKitResult({
    required this.text,
    required this.source,
    required this.imageUrl,
    required this.audioUrl,
    required this.wordList,
    required this.wordIndices,
    required this.calculateRange,
    required this.longestExactMatch,
  });

  /// The sentence in plain unformatted form.
  String text;

  /// The context from which the text was obtained.
  String source;

  /// The image of the context.
  String imageUrl;

  /// The audio of the context.
  String audioUrl;

  /// List of split words.
  List<String> wordList;

  /// Index of the words to highlight.
  List<int> wordIndices;

  TextRange? _calculatedRange;

  /// How many consecutive characters match the search term exactly
  int longestExactMatch;

  /// Function to calculate the range of search term
  TextRange Function() calculateRange;

  /// Get the range for this result for cloze purposes
  TextRange get range {
    _calculatedRange ??= calculateRange();
    return _calculatedRange!;
  }

  /// Get a selection with this result's text and range.
  JidoujishoTextSelection get selection => JidoujishoTextSelection(
        text: text,
        range: range,
      );
}

/// An enhancement used to fetch example sentences via Massif.
class ImmersionKitEnhancement extends Enhancement {
  /// Initialise this enhancement with the hardset parameters.
  ImmersionKitEnhancement()
      : super(
          uniqueKey: key,
          label: 'ImmersionKit',
          description:
              'Get example sentences complete with an image and audio.',
          icon: Icons.movie,
          field: TermField.instance,
        );

  /// Used to identify this enhancement and to allow a constant value for the
  /// default mappings value of [AnkiMapping].
  static const String key = 'immersion_kit';

  static const Map<String, List<String>> _caseSensitiveTitles = {
    'anime': [
      'Alya Sometimes Hides Her Feelings in Russian',
      'Angel Beats!',
      'Anohana the flower we saw that day',
      'Assassination Classroom Season 1',
      'Bakemonogatari',
      'Boku no Hero Academia Season 1',
      'Bunny Drop',
      'Cardcaptor Sakura',
      'Castle in the sky',
      'Chobits',
      'Clannad After Story',
      'Clannad',
      'Code Geass Season 1',
      'Daily Lives of High School Boys',
      'Death Note',
      'Demon Slayer - Kimetsu no Yaiba',
      'Durarara!!',
      'Erased',
      'Fairy Tail',
      'Fate Stay Night Unlimited Blade Works',
      'Fate Zero',
      'From Up on Poppy Hill',
      'From the New World',
      'Fruits Basket Season 1',
      'Fullmetal Alchemist Brotherhood',
      'Girls Band Cry',
      'God\'s Blessing on this Wonderful World!',
      'Grave of the Fireflies',
      'Haruhi Suzumiya',
      'Howl\'s Moving Castle',
      'Hunter × Hunter',
      'Hyouka',
      'Is The Order a Rabbit',
      'K-On!',
      'Kakegurui',
      'Kanon (2006)',
      'Kiki\'s Delivery Service',
      'Kill la Kill',
      'Kino\'s Journey',
      'Kokoro Connect',
      'Little Witch Academia',
      'Lucky Star',
      'Mahou Shoujo Madoka Magica',
      'Mononoke',
      'My Little Sister Can\'t Be This Cute',
      'My Neighbor Totoro',
      'New Game!',
      'Nisekoi',
      'No Game No Life',
      'Noragami',
      'One Week Friends',
      'Only Yesterday',
      'Princess Mononoke',
      'Psycho Pass',
      'Re Zero − Starting Life in Another World',
      'ReLIFE',
      'Shirokuma Cafe',
      'Sound! Euphonium',
      'Spirited Away',
      'Steins Gate',
      'Sword Art Online',
      'The Cat Returns',
      'The Garden of Words',
      'The Girl Who Leapt Through Time',
      'The Pet Girl of Sakurasou',
      'The Secret World of Arrietty',
      'The Wind Rises',
      'The World God Only Knows',
      'Toradora!',
      'Wandering Witch The Journey of Elaina',
      'Weathering with You',
      'When Marnie Was There',
      'Whisper of the Heart',
      'Wolf Children',
      'Your Lie in April',
      'Your Name',
    ],
    'drama': [
      '1 Litre of Tears',
      'Border',
      'Good Morning Call',
      'I am Mita, Your Housekeeper',
      'I\'m Taking the Day Off',
      'Legal High Season 1',
      'Million Yen Woman',
      'Mob Psycho 100',
      'Overprotected Kahoko',
      'Quartet',
      'Sailor Suit and Machine Gun (2006)',
      'Smoking',
      'The Journalist',
      'Weakest Beast',
    ],
    'games': [
      'Cyberpunk 2077',
      'Skyrim',
      'Witcher 3',
    ],
    'literature': [
      '黒猫',
      'おおかみと七ひきのこどもやぎ',
      'マッチ売りの少女',
      'サンタクロースがやってきた',
      '君死にたまふことなかれ',
      '蝉',
      '胡瓜',
      '若鮎について',
      '黒足袋',
      '柿',
      'お母さんの思ひ出',
      '砂をかむ',
      '虻のおれい',
      'がちゃがちゃ',
      '犬のいたずら',
      '犬と人形',
      '懐中時計',
      'きのこ会議',
      'お金とピストル',
      '梅のにおい',
      '純真',
      '声と人柄',
      '心の調べ',
      '愛',
      '期待と切望',
      '空の美',
      'いちょうの実',
      '虔十公園林',
      'クねずみ',
      'おきなぐさ',
      'さるのこしかけ',
      'セロ弾きのゴーシュ',
      'ざしき童子のはなし',
      '秋の歌',
      '赤い船とつばめ',
      '赤い蝋燭と人魚',
      '赤い魚と子供',
      '秋が　きました',
      '青いボタン',
      'ある夜の星たちの話',
      'いろいろな花',
      'からすとかがし',
      '片田舎にあった話',
      '金魚売り',
      '小鳥と兄妹',
      'おじいさんが捨てたら',
      'おかめどんぐり',
      'お母さん',
      'お母さんのお乳',
      'おっぱい',
      '少年と秋の日',
      '金のくびかざり',
      '愛よ愛',
      '気の毒な奥様',
      '新茶',
      '初夏に座す',
      '三角と四角',
      '赤い蝋燭',
      '赤とんぼ',
      '飴だま',
      'あし',
      'がちょうのたんじょうび',
      'ごん狐',
      '蟹のしょうばい',
      'カタツムリノ ウタ',
      '木の祭り',
      'こぞうさんのおきょう',
      '去年の木',
      'おじいさんのランプ',
      '王さまと靴屋',
      '落とした一銭銅貨',
      'サルト サムライ',
      '里の春、山の春',
      'ウサギ 新美 南吉',
      'あひるさん と 時計',
      '川へおちた玉ねぎさん',
      '小ぐまさんのかんがへちがひ',
      'お鍋とお皿とカーテン',
      'お鍋とおやかんとフライパンのけんくわ',
      'ひらめの学校',
      '狐物語',
      '桜の樹の下には',
      '瓜子姫子',
      'ああしんど',
      '葬式の行列',
      '風',
      '子どものすきな神さま',
      '喫茶店にて',
      '子供に化けた狐',
      '顔',
      '四季とその折々',
    ],
    'news': [
      '平成30年阿蘇神社で甘酒の仕込み始まる',
      'フレッシュマン！5月号阿蘇広域行政事務組合',
      'フレッシュマン！7月号春工房、そば処ゆう雀',
      'フレッシュマン！11月号内牧保育園',
      '山田小学校で最後の稲刈り',
    ],
  };

  static final Map<String, Map<String, String>> _normalizedTitleLookup = {
    for (var category in _caseSensitiveTitles.keys) 
      category: {
        for (var title in _caseSensitiveTitles[category]!) 
          _normalize(title): title
      }
  };

  static String _normalize(String s) => s.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  /// Used to store results that have already been found at runtime.
  final Map<String, List<ImmersionKitResult>> _immersionKitCache = {};

  /// Client used to communicate with the Massif API.
  final http.Client _client = http.Client();

  @override
  Future<void> enhanceCreatorParams({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required EnhancementTriggerCause cause,
  }) async {
    Directory appDirDoc = await getApplicationSupportDirectory();
    String immersionKitImagePath = '${appDirDoc.path}/immersion_kit';
    Directory immersionKitImageDir = Directory(immersionKitImagePath);
    if (immersionKitImageDir.existsSync()) {
      immersionKitImageDir.deleteSync(recursive: true);
    }
    immersionKitImageDir.createSync(recursive: true);

    String timestamp = DateFormat('yyyyMMddTkkmmss').format(DateTime.now());
    Directory directory = Directory('${immersionKitImageDir.path}/$timestamp');
    directory.createSync();

    String searchTerm = creatorModel.getFieldController(field).text;
    List<ImmersionKitResult> exampleSentences = await searchForSentences(
      appModel: appModel,
      searchTerm: searchTerm,
    );

    appModel.openImmersionKitSentenceDialog(
      exampleSentences: exampleSentences,
      onSelect: (selection) async {
        if (selection.isEmpty) {
          return;
        }

        final originalSelection = List<ImmersionKitResult>.from(selection);

        ImmersionKitResult firstResult = selection.removeAt(0);
        creatorModel.setSentenceAndCloze(firstResult.selection);
        creatorModel.getFieldController(ContextField.instance).text =
            firstResult.source;
        for (ImmersionKitResult result in selection) {
          creatorModel.appendSentenceAndCloze(result.text);
        }

        await _handleMedia(
          selection: originalSelection,
          cause: cause,
          appModel: appModel,
          creatorModel: creatorModel,
          directory: directory,
          searchTerm: searchTerm,
          isAppending: false,
        );
      },
      onAppend: (selection) async {
        if (selection.isEmpty) {
          return;
        }

        for (ImmersionKitResult result in selection) {
          creatorModel.appendSentenceAndCloze(result.text);
        }

        await _handleMedia(
          selection: selection,
          cause: cause,
          appModel: appModel,
          creatorModel: creatorModel,
          directory: directory,
          searchTerm: searchTerm,
          isAppending: true,
        );
      },
    );
  }

  /// Handles downloading and setting/appending images and audio for a
  /// list of selected ImmersionKit results.
  Future<void> _handleMedia({
    required List<ImmersionKitResult> selection,
    required EnhancementTriggerCause cause,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required Directory directory,
    required String searchTerm,
    required bool isAppending,
  }) async {

    final bool shouldSetImages =
        !isAppending || creatorModel.getFieldController(ImageField.instance).text.isEmpty;

    if (shouldSetImages) {
      final imageUrls = selection
          .map((r) => r.imageUrl)
          .where((url) => url.isNotEmpty)
          .toList();

      if (imageUrls.isNotEmpty) {
        await ImageField.instance.setImages(
          cause: cause,
          appModel: appModel,
          creatorModel: creatorModel,
          newAutoCannotOverride: false,
          generateImages: () async {
            final images = <NetworkToFileImage>[];
            for (var i = 0; i < imageUrls.length; i++) {
              final imagePath = isAppending
                  ? '${directory.path}/image_append_$i'
                  : '${directory.path}/image_$i';
              final imageFile = File(imagePath);
              final networkFile =
                  await DefaultCacheManager().getSingleFile(imageUrls[i]);
              await networkFile.copy(imageFile.path);
              images.add(NetworkToFileImage(file: imageFile));
            }
            return images;
          },
        );
      }
    }

    final bool shouldSetAudio = !isAppending ||
        creatorModel.getFieldController(AudioSentenceField.instance).text.isEmpty;

    if (shouldSetAudio) {
      final firstAudioUrl = selection
          .map((r) => r.audioUrl)
          .firstWhere((url) => url.isNotEmpty, orElse: () => '');

      if (firstAudioUrl.isNotEmpty) {
        await AudioSentenceField.instance.setAudio(
          appModel: appModel,
          creatorModel: creatorModel,
          searchTerm: searchTerm,
          newAutoCannotOverride: false,
          cause: cause,
          generateAudio: () async {
            final audioPath = isAppending ? '${directory.path}/audio_append.mp3' : '${directory.path}/audio.mp3';
            final audioFile = File(audioPath);
            final networkFile =
                await DefaultCacheManager().getSingleFile(firstAudioUrl);
            await networkFile.copy(audioFile.path);
            return audioFile;
          },
        );
      }
    }
  }

  TextRange _getRangeFromIndexedList({
    required List<int> wordIndices,
    required List<String> wordList,
    required String term,
  }) {
    if (wordIndices.isEmpty) {
      return TextRange.empty;
    } else {
      String beforeFirst = wordList.sublist(0, wordIndices.first).join();

      bool maybeIchidan = term.endsWith('る');
      String? godanEnding =
          godanConjugations.keys.contains(term.characters.last)
              ? term.characters.last
              : null;

      var length = wordList[wordIndices.first].length;
      var index = wordIndices.first + 1;
      // Keep adding to the cloze, if:
      // - it is shorter than the term
      // - it might be a conjugated godan verb (longer than term)
      //    AND the next word is a valid conjugation for the godan verb
      // - we are not at the end of the sentence
      while (
          // - we are not at the end of the sentence
          index < wordList.length &&
              (
                  // - it is shorter than the term
                  length < term.length ||
                      // - it might be a conjugated godan verb (longer than term)
                      (godanEnding != null &&
                          length == term.length &&
                          // AND the next word is a valid conjugation for the godan verb
                          godanConjugations[godanEnding]!.contains(
                              wordList[index - 1].characters.last +
                                  wordList[index])))) {
        var nextWord = wordList[index];

        // If the term could be an ichidan verb, we are one letter short of the
        // whole term, and the next word is not a possible conjugation for
        // ichidan or godan with る, break and return the stem
        if (maybeIchidan &&
            length == term.length - 1 &&
            !ichidanConjugations.contains(nextWord) &&
            !godanConjugations['る']!.contains(nextWord)) {
          break;
        }

        length += nextWord.length;
        index++;
      }

      return TextRange(
        start: beforeFirst.length,
        end: beforeFirst.length + length,
      );
    }
  }

  int _longestExactRangeForResult({
    required List<int> wordIndices,
    required List<String> wordList,
    required String term,
    required String text,
  }) {
    if (wordIndices.isEmpty) {
      return 0;
    }

    /// Start at the first character of the given cloze
    int textPosition = wordList.sublist(0, wordIndices.first).join().length;
    int termPosition = 0;

    while (textPosition < text.length &&
        termPosition < term.length &&
        term[termPosition] == text[textPosition]) {
      termPosition++;
      textPosition++;
    }

    return termPosition;
  }

  /// Search the ImmersionKit v2 API for example sentences and return a list of results.
  Future<List<ImmersionKitResult>> searchForSentences({
    required AppModel appModel,
    required String searchTerm,
  }) async {
    if (searchTerm.trim().isEmpty) {
      return [];
    }

    if (_immersionKitCache[searchTerm] != null) {
      return _immersionKitCache[searchTerm]!;
    }

    List<ImmersionKitResult> results = [];

    try {
      /// Query the ImmersionKit API v2 for results.
      final response = await _client.get(Uri.parse(
          'https://apiv2.immersionkit.com/search?q=${Uri.encodeComponent(searchTerm)}&exactMatch=true'));

      if (response.statusCode != 200) {
        // Don't throw, just report and return empty.
        appModel.showFailedToCommunicateMessage();
        return [];
      }

      Map<String, dynamic> json = jsonDecode(utf8.decode(response.bodyBytes));

      List<Map<String, dynamic>> examples =
          List<Map<String, dynamic>>.from(json['examples'] ?? []);

      for (Map<String, dynamic> example in examples) {
        String source = example['title'] ?? '';
        String text = example['sentence'] ?? '';
        if (text.isEmpty) {
          continue;
        }

        List<String> wordList = List<String>.from(example['word_list'] ?? []);
        List<int> wordIndices = [];

        // Manually find the index of the first word of the search term
        int termStartIndex = text.indexOf(searchTerm);
        if (termStartIndex != -1) {
          int currentPos = 0;
          for (int i = 0; i < wordList.length; i++) {
            String word = wordList[i];
            if (currentPos <= termStartIndex &&
                termStartIndex < currentPos + word.length) {
              wordIndices.add(i);
              break;
            }
            currentPos += word.length;
          }
        }

        String id = example['id'] ?? '';
        List<String> idParts = id.split('_');
        String category = idParts.isNotEmpty ? idParts.first : '';

        final normalizedApiTitle = _normalize(source);
        final correctTitle = _normalizedTitleLookup[category]?[normalizedApiTitle];

        String imageUrl = '';
        String imageFilename = example['image'] ?? '';
        if (category.isNotEmpty &&
            correctTitle != null &&
            imageFilename.isNotEmpty) {
          final encodedTitle = Uri.encodeComponent(correctTitle);
          imageUrl =
              'https://us-southeast-1.linodeobjects.com/immersionkit/media/$category/$encodedTitle/media/$imageFilename';
        }

        String audioUrl = '';
        String soundFilename = example['sound'] ?? '';
        if (category.isNotEmpty &&
            correctTitle != null &&
            soundFilename.isNotEmpty) {
          final encodedTitle = Uri.encodeComponent(correctTitle);
          audioUrl =
              'https://us-southeast-1.linodeobjects.com/immersionkit/media/$category/$encodedTitle/media/$soundFilename';
        }

        ImmersionKitResult result = ImmersionKitResult(
            text: text,
            source: source,
            imageUrl: imageUrl,
            audioUrl: audioUrl,
            wordList: wordList,
            wordIndices: wordIndices,
            calculateRange: () => _getRangeFromIndexedList(
                  wordIndices: wordIndices,
                  wordList: wordList,
                  term: searchTerm,
                ),
            longestExactMatch: _longestExactRangeForResult(
              wordIndices: wordIndices,
              wordList: wordList,
              text: text,
              term: searchTerm,
            ));

        /// Sentence examples that are merely the word itself are pretty
        /// redundant.
        if (result.text != searchTerm) {
          results.add(result);
        }
      }

      /// Make sure series aren't too consecutive.
      results.shuffle();

      /// Sort by: has image -> has audio -> longest exact match -> shortest sentence
      results.sort((a, b) {
        int hasImage = (a.imageUrl.isNotEmpty ? -1 : 1)
            .compareTo(b.imageUrl.isNotEmpty ? -1 : 1);

        if (hasImage != 0) {
          return hasImage;
        }

        int hasAudio = (a.audioUrl.isNotEmpty ? -1 : 1)
            .compareTo(b.audioUrl.isNotEmpty ? -1 : 1);

        if (hasAudio != 0) {
          return hasAudio;
        }

        /// Sort by longest subterm
        int longestMatch = b.longestExactMatch.compareTo(a.longestExactMatch);

        if (longestMatch != 0) {
          return longestMatch;
        }

        return a.text.length.compareTo(b.text.length);
      });

      /// Save this into cache.
      _immersionKitCache[searchTerm] = results;

      return results;
    } catch (e) {
      /// Used to log if this third-party service is down or changes domains.
      appModel.showFailedToCommunicateMessage();
      return [];
    }
  }
}
