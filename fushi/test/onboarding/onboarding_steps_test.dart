import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/onboarding/onboarding_steps.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';

/// 默认按「复习方式选 Anki」取序列：本文件的既有用例钉的是原 Anki 流程；Fushi 复习
/// 路径见下面的 `review method` 组。
List<OnboardingStepId> _steps(
  Set<OnboardingFeature> selected, {
  bool browserExtensionAvailable = false,
  bool globalLookupAvailable = false,
  bool ankiReady = false,
  bool srsEnabled = false,
  OnboardingReviewMethod reviewMethod = OnboardingReviewMethod.anki,
}) => onboardingStepSequence(
  selected: selected,
  browserExtensionAvailable: browserExtensionAvailable,
  globalLookupAvailable: globalLookupAvailable,
  ankiReady: ankiReady,
  srsEnabled: srsEnabled,
  reviewMethod: reviewMethod,
);

void main() {
  group('onboardingStepSequence', () {
    test('first card readiness rejects cached or stale Anki selections', () {
      expect(
        onboardingAnkiSelectionReady(
          connectionVerified: false,
          selectedDeckId: 1,
          selectedNoteTypeId: 2,
          availableDeckIds: <int>[1],
          availableNoteTypeIds: <int>[2],
        ),
        isFalse,
      );
      expect(
        onboardingAnkiSelectionReady(
          connectionVerified: true,
          selectedDeckId: 999,
          selectedNoteTypeId: 2,
          availableDeckIds: <int>[1],
          availableNoteTypeIds: <int>[2],
        ),
        isFalse,
      );
      expect(
        onboardingAnkiSelectionReady(
          connectionVerified: true,
          selectedDeckId: 1,
          selectedNoteTypeId: 2,
          availableDeckIds: <int>[1],
          availableNoteTypeIds: <int>[2],
        ),
        isTrue,
      );
    });

    test('empty selection yields fixed skeleton without lookup tutorials', () {
      expect(_steps(<OnboardingFeature>{}), <OnboardingStepId>[
        OnboardingStepId.welcome,
        OnboardingStepId.features,
        OnboardingStepId.finish,
      ]);
    });

    test('fonts step follows its own selection like any capability', () {
      expect(
        _steps(<OnboardingFeature>{OnboardingFeature.fonts}),
        <OnboardingStepId>[
          OnboardingStepId.welcome,
          OnboardingStepId.features,
          OnboardingStepId.fonts,
          OnboardingStepId.finish,
        ],
      );
      // 字体排在所有配置步骤之后、操作教程之前。备份步骤要连带勾它的总闸模块
      // sync（模块关掉 = 它名下的配置步骤一并不出）。
      expect(
        _steps(<OnboardingFeature>{
          OnboardingFeature.fonts,
          OnboardingFeature.backup,
          OnboardingFeature.sync,
          OnboardingFeature.manualResources,
        }),
        containsAllInOrder(<OnboardingStepId>[
          OnboardingStepId.backup,
          OnboardingStepId.fonts,
          OnboardingStepId.clickLookup,
        ]),
      );
    });

    test('extension guide needs both desktop capability and selection', () {
      final Set<OnboardingFeature> selected = <OnboardingFeature>{
        OnboardingFeature.web,
      };
      expect(
        _steps(selected, browserExtensionAvailable: true),
        contains(OnboardingStepId.browserExtension),
      );
      expect(
        _steps(selected),
        isNot(contains(OnboardingStepId.browserExtension)),
      );
    });

    test('recommended pack unlocks lookup tutorials', () {
      // 应用外全局查词教程归 lookup 模块管（模块关掉时连系统热键都不该装），
      // 故要连带勾 lookup；应用内点击查词教程是能力，不受模块门控。
      final List<OnboardingStepId> result = _steps(<OnboardingFeature>{
        OnboardingFeature.recommendedPack,
        OnboardingFeature.lookup,
      }, globalLookupAvailable: true);
      expect(
        result,
        containsAllInOrder(<OnboardingStepId>[
          OnboardingStepId.recommendedPack,
          OnboardingStepId.clickLookup,
          OnboardingStepId.globalLookup,
        ]),
      );
    });

    test('manual resources independently unlock lookup tutorials', () {
      final List<OnboardingStepId> result = _steps(<OnboardingFeature>{
        OnboardingFeature.manualResources,
        OnboardingFeature.lookup,
      }, globalLookupAvailable: true);
      expect(result, contains(OnboardingStepId.manualResources));
      expect(result, isNot(contains(OnboardingStepId.recommendedPack)));
      expect(result, contains(OnboardingStepId.clickLookup));
      expect(result, contains(OnboardingStepId.globalLookup));
    });

    test('recommended pack and manual resources can both be selected', () {
      final List<OnboardingStepId> result = _steps(<OnboardingFeature>{
        OnboardingFeature.recommendedPack,
        OnboardingFeature.manualResources,
      });
      expect(
        result,
        containsAllInOrder(<OnboardingStepId>[
          OnboardingStepId.recommendedPack,
          OnboardingStepId.manualResources,
          OnboardingStepId.clickLookup,
        ]),
      );
    });

    test('global tutorial still follows its platform capability gate', () {
      // 勾上 lookup 模块，剩下的唯一变量就是平台能力（本用例默认不可用）。
      final Set<OnboardingFeature> selected = <OnboardingFeature>{
        OnboardingFeature.manualResources,
        OnboardingFeature.lookup,
      };
      expect(_steps(selected), contains(OnboardingStepId.clickLookup));
      expect(_steps(selected), isNot(contains(OnboardingStepId.globalLookup)));
      expect(
        _steps(selected, globalLookupAvailable: true),
        contains(OnboardingStepId.globalLookup),
      );
    });

    test('global tutorial disappears when the lookup module is unchecked', () {
      // 应用外全局取词与 `ShortcutScope.globalExternal` 同属 lookup 模块：模块
      // 未勾时即便平台可用也不出这一步。应用内点击查词教程教的是划词弹窗这一
      // 能力，按定好的例外一律保留。
      final List<OnboardingStepId> result = _steps(<OnboardingFeature>{
        OnboardingFeature.manualResources,
      }, globalLookupAvailable: true);
      expect(result, contains(OnboardingStepId.clickLookup));
      expect(result, isNot(contains(OnboardingStepId.globalLookup)));
    });

    test(
      'first Anki card needs resources, Anki selection, and live readiness',
      () {
        // Anki 配置步骤（及其下游的第一张卡教程）归 cardCreation 模块管，
        // 两道门都要过。
        final Set<OnboardingFeature> complete = <OnboardingFeature>{
          OnboardingFeature.manualResources,
          OnboardingFeature.anki,
          OnboardingFeature.cardCreation,
        };
        expect(
          _steps(complete),
          isNot(contains(OnboardingStepId.firstAnkiCard)),
        );
        expect(
          _steps(complete, ankiReady: true),
          containsAllInOrder(<OnboardingStepId>[
            OnboardingStepId.anki,
            OnboardingStepId.clickLookup,
            OnboardingStepId.firstAnkiCard,
          ]),
        );
        expect(
          _steps(<OnboardingFeature>{
            OnboardingFeature.anki,
            OnboardingFeature.cardCreation,
          }, ankiReady: true),
          isNot(contains(OnboardingStepId.firstAnkiCard)),
        );
        // 制卡模块未勾：Anki 配置步骤与第一张卡教程一起消失。
        final List<OnboardingStepId> withoutModule = _steps(<OnboardingFeature>{
          OnboardingFeature.manualResources,
          OnboardingFeature.anki,
        }, ankiReady: true);
        expect(withoutModule, isNot(contains(OnboardingStepId.anki)));
        expect(withoutModule, isNot(contains(OnboardingStepId.firstAnkiCard)));
        expect(
          _steps(<OnboardingFeature>{
            OnboardingFeature.manualResources,
          }, ankiReady: true),
          isNot(contains(OnboardingStepId.firstAnkiCard)),
        );
      },
    );

    test('full selection yields all steps in stable order', () {
      expect(
        _steps(
          OnboardingFeature.values.toSet(),
          browserExtensionAvailable: true,
          globalLookupAvailable: true,
          ankiReady: true,
        ),
        <OnboardingStepId>[
          OnboardingStepId.welcome,
          OnboardingStepId.features,
          OnboardingStepId.recommendedPack,
          OnboardingStepId.manualResources,
          OnboardingStepId.reviewMethod,
          OnboardingStepId.anki,
          OnboardingStepId.onlineServices,
          OnboardingStepId.backup,
          OnboardingStepId.interconnect,
          OnboardingStepId.browserExtension,
          OnboardingStepId.fonts,
          OnboardingStepId.clickLookup,
          OnboardingStepId.globalLookup,
          OnboardingStepId.firstAnkiCard,
          OnboardingStepId.finish,
        ],
      );
    });

    test('library module features add no steps and gate none', () {
      // 模块勾选自身从不产生步骤；库页四模块名下也没有任何配置步骤，故叠不叠
      // 都一字不变。真正当总闸的是 cardCreation / sync / browserExtension /
      // lookup 四个，各由本 group 里对应的用例覆盖。
      const Set<OnboardingFeature> libraryModules = <OnboardingFeature>{
        OnboardingFeature.books,
        OnboardingFeature.manga,
        OnboardingFeature.video,
        OnboardingFeature.games,
      };
      expect(_steps(libraryModules), _steps(<OnboardingFeature>{}));

      const Set<OnboardingFeature> capabilities = <OnboardingFeature>{
        OnboardingFeature.manualResources,
        OnboardingFeature.anki,
        OnboardingFeature.cardCreation,
        OnboardingFeature.backup,
        OnboardingFeature.interconnect,
        OnboardingFeature.sync,
        OnboardingFeature.fonts,
        OnboardingFeature.lookup,
      };
      expect(
        _steps(
          <OnboardingFeature>{...capabilities, ...libraryModules},
          globalLookupAvailable: true,
          ankiReady: true,
        ),
        _steps(capabilities, globalLookupAvailable: true, ankiReady: true),
      );
    });

    test(
      'non-resource capabilities map to their own steps behind their module',
      () {
        // 配置能力现在要过**两道门**：能力自身被勾 + 它所属的功能模块也被勾
        // （模块是本模块名下配置步骤的总闸）。fonts 不属于任何模块，只有一道门。
        const Map<OnboardingFeature, OnboardingStepId> capabilitySteps =
            <OnboardingFeature, OnboardingStepId>{
              OnboardingFeature.anki: OnboardingStepId.anki,
              OnboardingFeature.fonts: OnboardingStepId.fonts,
              OnboardingFeature.backup: OnboardingStepId.backup,
              OnboardingFeature.interconnect: OnboardingStepId.interconnect,
            };
        const Map<OnboardingFeature, OnboardingFeature?> owningModule =
            <OnboardingFeature, OnboardingFeature?>{
              OnboardingFeature.anki: OnboardingFeature.cardCreation,
              OnboardingFeature.fonts: null,
              OnboardingFeature.backup: OnboardingFeature.sync,
              OnboardingFeature.interconnect: OnboardingFeature.sync,
            };
        capabilitySteps.forEach((
          OnboardingFeature feature,
          OnboardingStepId step,
        ) {
          final OnboardingFeature? module = owningModule[feature];
          final List<OnboardingStepId> result = _steps(<OnboardingFeature>{
            feature,
            if (module != null) module,
          });
          expect(result, contains(step), reason: '$feature 应产生 $step');
          // 制卡能力多一步「复习方式」打头。
          expect(
            result,
            hasLength(feature == OnboardingFeature.anki ? 5 : 4),
            reason: '$feature 应只追加它自己的配置步骤',
          );

          if (module == null) return;
          // 所属模块未勾：能力勾了也不出步骤，只剩骨架三步。
          final List<OnboardingStepId> gated = _steps(<OnboardingFeature>{
            feature,
          });
          expect(gated, isNot(contains(step)), reason: '$module 未勾时不该出 $step');
          expect(gated, hasLength(3), reason: '$feature 被模块挡住时不该追加步骤');
        });
      },
    );
  });

  // 「复习方式」（所有者 2026-10-16）：制卡相关步骤以它打头。选 Fushi 复习跳过全部
  // Anki 专属步骤、改出复习介绍；选 Anki 与原流程逐步一致。
  group('review method', () {
    final Set<OnboardingFeature> all = OnboardingFeature.values.toSet();

    test('the default is Fushi review', () {
      expect(
        onboardingStepSequence(
          selected: all,
          browserExtensionAvailable: true,
          globalLookupAvailable: true,
          ankiReady: true,
        ),
        _steps(
          all,
          browserExtensionAvailable: true,
          globalLookupAvailable: true,
          ankiReady: true,
          reviewMethod: OnboardingReviewMethod.fushi,
        ),
      );
    });

    test('Fushi review skips every Anki-only step', () {
      final List<OnboardingStepId> fushi = _steps(
        all,
        browserExtensionAvailable: true,
        globalLookupAvailable: true,
        // 即便 Anki 恰好已就绪，Fushi 路径也不出「第一张 Anki 卡」。
        ankiReady: true,
        reviewMethod: OnboardingReviewMethod.fushi,
      );
      expect(fushi, <OnboardingStepId>[
        OnboardingStepId.welcome,
        OnboardingStepId.features,
        OnboardingStepId.recommendedPack,
        OnboardingStepId.manualResources,
        OnboardingStepId.reviewMethod,
        OnboardingStepId.onlineServices,
        OnboardingStepId.backup,
        OnboardingStepId.interconnect,
        OnboardingStepId.browserExtension,
        OnboardingStepId.fonts,
        OnboardingStepId.clickLookup,
        OnboardingStepId.globalLookup,
        OnboardingStepId.srs,
        OnboardingStepId.finish,
      ]);
      expect(fushi, isNot(contains(OnboardingStepId.anki)));
      expect(fushi, isNot(contains(OnboardingStepId.firstAnkiCard)));
    });

    test('Anki keeps the original flow (plus the choice up front)', () {
      final List<OnboardingStepId> anki = _steps(
        all,
        browserExtensionAvailable: true,
        globalLookupAvailable: true,
        ankiReady: true,
      );
      expect(
        anki.where((OnboardingStepId s) => s != OnboardingStepId.reviewMethod),
        <OnboardingStepId>[
          OnboardingStepId.welcome,
          OnboardingStepId.features,
          OnboardingStepId.recommendedPack,
          OnboardingStepId.manualResources,
          OnboardingStepId.anki,
          OnboardingStepId.onlineServices,
          OnboardingStepId.backup,
          OnboardingStepId.interconnect,
          OnboardingStepId.browserExtension,
          OnboardingStepId.fonts,
          OnboardingStepId.clickLookup,
          OnboardingStepId.globalLookup,
          OnboardingStepId.firstAnkiCard,
          OnboardingStepId.finish,
        ],
      );
      expect(anki, isNot(contains(OnboardingStepId.srs)));
      expect(
        anki.indexOf(OnboardingStepId.reviewMethod),
        anki.indexOf(OnboardingStepId.anki) - 1,
      );
    });

    test(
      'card creation unchecked: no choice, SRS intro follows the module',
      () {
        final Set<OnboardingFeature> noCards = OnboardingFeature.values.toSet()
          ..remove(OnboardingFeature.cardCreation);
        for (final OnboardingReviewMethod m in OnboardingReviewMethod.values) {
          final List<OnboardingStepId> off = _steps(noCards, reviewMethod: m);
          expect(off, isNot(contains(OnboardingStepId.reviewMethod)));
          expect(off, isNot(contains(OnboardingStepId.anki)));
          expect(off, isNot(contains(OnboardingStepId.srs)));
          final List<OnboardingStepId> on = _steps(
            noCards,
            reviewMethod: m,
            srsEnabled: true,
          );
          expect(on[on.length - 2], OnboardingStepId.srs);
        }
      },
    );

    test('initial choice is Fushi SRS regardless of the live state', () {
      // 所有者 2026-10-20：新手教程默认 Fushi 复习（此前老用户重开向导默认 Anki）。
      expect(kOnboardingDefaultReviewMethod, OnboardingReviewMethod.fushi);
    });

    test('choosing writes module + mining target', () async {
      final Map<ModuleId, bool> modules = <ModuleId, bool>{};
      final List<SrsMiningTarget> targets = <SrsMiningTarget>[];
      Future<void> setModule(ModuleId m, bool v) async => modules[m] = v;
      Future<void> setTarget(SrsMiningTarget t) async => targets.add(t);

      int adopted = 0;
      Future<void> adopt() async => adopted++;

      await applyOnboardingReviewMethod(
        OnboardingReviewMethod.fushi,
        setModuleEnabled: setModule,
        setMiningTarget: setTarget,
        adoptFushiCard: adopt,
      );
      expect(modules, <ModuleId, bool>{ModuleId.srs: true});
      expect(targets.last, SrsMiningTarget.srs);
      expect(adopted, 1, reason: '选 Fushi 复习要把制卡笔记类型落到 Fushi 卡片');

      await applyOnboardingReviewMethod(
        OnboardingReviewMethod.anki,
        setModuleEnabled: setModule,
        setMiningTarget: setTarget,
        adoptFushiCard: adopt,
      );
      expect(modules, <ModuleId, bool>{ModuleId.srs: false});
      expect(targets.last, SrsMiningTarget.anki);
      expect(adopted, 1, reason: '选 Anki 不碰 Fushi 复习的笔记类型');
    });

    test('the wizard offers no SRS checkbox (the choice step writes it)', () {
      expect(onboardingFeatureOfModule(ModuleId.srs), isNull);
      expect(
        OnboardingFeature.values.map(moduleOfOnboardingFeature),
        isNot(contains(ModuleId.srs)),
      );
    });
  });

  group('usage purpose', () {
    const Set<OnboardingFeature> freshInstall = <OnboardingFeature>{
      ...kOnboardingDefaultCapabilities,
      OnboardingFeature.books,
      OnboardingFeature.video,
      OnboardingFeature.lookup,
      OnboardingFeature.cardCreation,
      OnboardingFeature.sync,
    };

    test('media only drops every language-learning step', () {
      final Set<OnboardingFeature> media = onboardingSelectionForPurpose(
        OnboardingUsagePurpose.mediaOnly,
        <OnboardingFeature>{...freshInstall, OnboardingFeature.manualResources},
      );
      expect(media.intersection(kOnboardingLanguageLearningFeatures), isEmpty);
      // 与学外语无关的选择原样保留。
      expect(
        media,
        containsAll(<OnboardingFeature>[
          OnboardingFeature.books,
          OnboardingFeature.video,
          OnboardingFeature.sync,
          OnboardingFeature.fonts,
        ]),
      );
      final List<OnboardingStepId> steps = _steps(
        media,
        globalLookupAvailable: true,
        ankiReady: true,
        reviewMethod: OnboardingReviewMethod.fushi,
        srsEnabled:
            onboardingSrsModuleOverride(
              purpose: OnboardingUsagePurpose.mediaOnly,
              selected: media,
            ) ??
            true,
      );
      expect(
        steps,
        isNot(
          anyOf(<Matcher>[
            contains(OnboardingStepId.recommendedPack),
            contains(OnboardingStepId.manualResources),
            contains(OnboardingStepId.reviewMethod),
            contains(OnboardingStepId.anki),
            contains(OnboardingStepId.clickLookup),
            contains(OnboardingStepId.globalLookup),
            contains(OnboardingStepId.firstAnkiCard),
            contains(OnboardingStepId.srs),
          ]),
        ),
      );
      expect(steps, contains(OnboardingStepId.fonts));
    });

    test('switching back to learning restores the factory presets', () {
      final Set<OnboardingFeature> roundTrip = onboardingSelectionForPurpose(
        OnboardingUsagePurpose.languageLearning,
        onboardingSelectionForPurpose(
          OnboardingUsagePurpose.mediaOnly,
          freshInstall,
        ),
      );
      expect(roundTrip, freshInstall);
    });

    test('initial purpose follows lookup and card creation modules', () {
      expect(
        onboardingUsagePurposeOf(
          lookupModuleEnabled: true,
          cardCreationModuleEnabled: true,
        ),
        OnboardingUsagePurpose.languageLearning,
      );
      expect(
        onboardingUsagePurposeOf(
          lookupModuleEnabled: false,
          cardCreationModuleEnabled: true,
        ),
        OnboardingUsagePurpose.languageLearning,
      );
      expect(
        onboardingUsagePurposeOf(
          lookupModuleEnabled: false,
          cardCreationModuleEnabled: false,
        ),
        OnboardingUsagePurpose.mediaOnly,
      );
    });

    test('srs is only switched off for media only without card creation', () {
      expect(
        onboardingSrsModuleOverride(
          purpose: OnboardingUsagePurpose.mediaOnly,
          selected: <OnboardingFeature>{},
        ),
        isFalse,
      );
      // 用户在方格里手动勾回制卡：交给「复习方式」一步决定。
      expect(
        onboardingSrsModuleOverride(
          purpose: OnboardingUsagePurpose.mediaOnly,
          selected: <OnboardingFeature>{OnboardingFeature.cardCreation},
        ),
        isNull,
      );
      expect(
        onboardingSrsModuleOverride(
          purpose: OnboardingUsagePurpose.languageLearning,
          selected: <OnboardingFeature>{},
        ),
        isNull,
      );
    });
  });
}
