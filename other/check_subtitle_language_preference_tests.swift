//
//  check_subtitle_language_preference_tests.swift
//  iina
//
//  Cases for `SubtitleLanguagePreference` and `SubtitleSelectionPlan`, run by
//  `other/check_subtitle_language_preference.sh`.
//
//  This file is concatenated after the extracted scorer, language rules, and selection plan and
//  compiled as `main.swift`, so its top level is the program entry point. It is not part of the app
//  target.
//
//  Two rules are under test. A preference that is not recognized must never be silently turned into
//  a preference for something else, and it must never be dropped in a way that makes a result in a
//  different language look preferred. And a result is downloaded and made active with no prompt only
//  when the evidence rule and the language rule both leave exactly one candidate.
//

import Foundation

var failures = 0
var total = 0

func fail(_ message: String) {
  failures += 1
  print("FAIL  \(message)")
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
  total += 1
  if actual != expected {
    fail("\(label): expected \(expected), got \(actual)")
  }
}

func expectNil<T>(_ actual: T?, _ label: String) {
  total += 1
  if let actual {
    fail("\(label): expected no value, got \(actual)")
  }
}

func section(_ title: String) {
  print("\n— \(title)")
}

// MARK: - Canonical language

section("every spelling of one language reduces to the same canonical subtag")

let aliases: [(label: String, token: String?, expected: String?)] = [
  ("two-letter code", "en", "en"),
  ("three-letter code", "eng", "en"),
  ("English name", "English", "en"),
  ("lowercase name from SubDL", "english", "en"),
  ("uppercase name", "SPANISH", "es"),
  ("two-letter Spanish", "es", "es"),
  ("three-letter Spanish", "spa", "es"),
  ("three-letter Portuguese", "por", "pt"),
  ("regional Portuguese", "pt-br", "pt"),
  ("regional Chinese", "zh-cn", "zh"),
  ("script-qualified Chinese", "zh-Hans", "zh"),
  ("three-letter Chinese", "chi", "zh"),
  ("legacy three-letter Chinese", "zho", "zh"),
  ("assrt simplified Chinese", "简体", "zh"),
  ("assrt traditional Chinese", "繁体", "zh"),
  ("assrt English", "英文", "en"),
  ("assrt Japanese", "日文", "ja"),
  ("surrounding whitespace", "  en  ", "en"),
  ("padded three-letter code", " eng\t", "en"),
  ("empty", "", nil),
  ("whitespace only", "   ", nil),
  ("absent", nil, nil),
  ("bilingual assrt description", "双语", nil),
  ("unknown name", "klingon", nil),
  ("parenthesized code", "(en)", nil),
  ("unassigned subtag", "und", nil),
  ("multiple languages subtag", "mul", nil),
  ("no linguistic content", "zxx", nil),
  ("CJK text that is not a mapped description", "日本語", nil),
  ("digits", "12", nil),
]

for entry in aliases {
  expectEqual(SubtitleLanguagePreference.canonical(entry.token), entry.expected,
              "canonical(\(entry.token ?? "nil")) — \(entry.label)")
}

// MARK: - The preferred list

section("the setting is read in order and never falls back to nothing")

expectEqual(SubtitleLanguagePreference.preferred(from: nil), ["en"], "unset setting prefers English")
expectEqual(SubtitleLanguagePreference.preferred(from: ""), ["en"], "empty setting prefers English")
expectEqual(SubtitleLanguagePreference.preferred(from: "eng"), ["en"], "three-letter setting")
expectEqual(SubtitleLanguagePreference.preferred(from: "en,spa"), ["en", "es"], "codes are canonicalized")
expectEqual(SubtitleLanguagePreference.preferred(from: "eng, spa, 英文"), ["en", "es"], "duplicates collapse")
expectEqual(SubtitleLanguagePreference.preferred(from: "spa,en"), ["es", "en"], "order is preserved")
expectEqual(SubtitleLanguagePreference.preferred(from: "klingon,spa"), ["es"], "unrecognized tokens drop out")
expectEqual(SubtitleLanguagePreference.preferred(from: "klingon"), ["en"], "an unusable setting falls back")
expectEqual(SubtitleLanguagePreference.preferred(from: " , ,"), ["en"], "separators alone fall back")
expectEqual(SubtitleLanguagePreference.preferredForSelection(from: "pt-BR,en"),
            ["pt-br", "en"], "selection retains explicit regional preference")
expectEqual(SubtitleLanguagePreference.preferredForSelection(from: "zh-Hant"),
            ["zh-tw"], "selection maps a Chinese script to its provider region")

section("a result's language is ranked against the list, and unknowns rank nowhere")

expectEqual(SubtitleLanguagePreference.rank(of: "en", in: ["en", "es"]), 0, "first preference")
expectEqual(SubtitleLanguagePreference.rank(of: "eng", in: ["en", "es"]), 0, "three-letter result")
expectEqual(SubtitleLanguagePreference.rank(of: "fr", in: ["en", "fr"]), 1, "second preference")
expectEqual(SubtitleLanguagePreference.rank(of: "pt-br", in: ["pt"]), 0, "regional result")
expectEqual(SubtitleLanguagePreference.rank(of: "pt-br", in: ["pt-br"]), 0, "exact regional result")
expectEqual(SubtitleLanguagePreference.rank(of: "pt-pt", in: ["pt-br", "pt-pt"]), 1,
            "an exact second regional preference outranks a generic result")
expectNil(SubtitleLanguagePreference.rank(of: "pt", in: ["pt-br", "pt-pt"]),
          "a regionless result cannot claim either explicit region")
expectNil(SubtitleLanguagePreference.rank(of: "pt-pt", in: ["pt-br"]), "other region does not match")
expectEqual(SubtitleLanguagePreference.rank(of: "en-US", in: ["en"]), 0, "language-only preference matches a region")
expectNil(SubtitleLanguagePreference.rank(of: "en", in: ["en-us"]),
          "a language-only result cannot claim an explicit region")
expectNil(SubtitleLanguagePreference.rank(of: "fr", in: ["en"]), "language not asked for")
expectNil(SubtitleLanguagePreference.rank(of: nil, in: ["en"]), "provider reported nothing")
expectNil(SubtitleLanguagePreference.rank(of: "双语", in: ["zh"]), "bilingual description")
expectNil(SubtitleLanguagePreference.rank(of: "en", in: []), "empty list")

section("OpenSubtitles keeps explicit regions and expands broad preferences")

let openSubCodes = ["en", "pt-pt", "pt-br", "zh-cn", "zh-tw"]
expectEqual(SubtitleLanguagePreference.providerCodes(from: "pt-BR", supportedCodes: openSubCodes),
            ["pt-br"], "explicit Brazilian Portuguese stays regional")
expectEqual(SubtitleLanguagePreference.providerCodes(from: "zh_tw", supportedCodes: openSubCodes),
            ["zh-tw"], "underscore regional spelling is normalized")
expectEqual(SubtitleLanguagePreference.providerCodes(from: "zh-Hant", supportedCodes: openSubCodes),
            ["zh-tw"], "traditional Chinese script maps to the supported Taiwan code")
expectEqual(SubtitleLanguagePreference.providerCodes(from: "pt", supportedCodes: openSubCodes),
            ["pt-pt", "pt-br"], "broad Portuguese includes both supported regional codes")
expectEqual(SubtitleLanguagePreference.providerCodes(from: "pt-AO", supportedCodes: openSubCodes),
            [], "an unsupported explicit Portuguese region does not broaden")
expectEqual(SubtitleLanguagePreference.providerCodes(from: "pt-BR,en", supportedCodes: openSubCodes),
            ["pt-br", "en"], "regional and language-only tokens retain their preference order")

// MARK: - The selection decision

section("automatic selection")

// Title in two languages, both exact matches with provider evidence, preference English: the
// language decides, and the decision is no longer left to the provider's ordering.
expectEqual(
  SubtitleSelectionPlan.decide(scores: [100, 100], languageRanks: [1, 0], canAutomaticallySelect: [true, true],
                               selectionBoosts: [0, 0], autoSelectEnabled: true).autoSelected,
  1, "preferred language wins between two exact matches")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [100, 100], languageRanks: [0, 0], canAutomaticallySelect: [true, true],
                               selectionBoosts: [0, 0], autoSelectEnabled: true).autoSelected,
  nil, "two exact matches in the preferred language stay ambiguous")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [100, 100], languageRanks: [nil, nil], canAutomaticallySelect: [true, true],
                               selectionBoosts: [0, 0], autoSelectEnabled: true).autoSelected,
  nil, "two exact matches with unknown languages stay ambiguous")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [100, 100], languageRanks: [1, 2], canAutomaticallySelect: [true, true],
                               selectionBoosts: [0, 0], autoSelectEnabled: true).autoSelected,
  0, "between two preferred languages the earlier preference wins")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [100, 100], languageRanks: [nil, 2], canAutomaticallySelect: [true, true],
                               selectionBoosts: [0, 0], autoSelectEnabled: true).autoSelected,
  1, "a lower preference still beats a language the provider could not identify")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [100], languageRanks: [nil], canAutomaticallySelect: [true],
                               selectionBoosts: [0], autoSelectEnabled: true).autoSelected,
  0, "one exact match with an unknown language is still selected")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [100, 95], languageRanks: [nil, 0], canAutomaticallySelect: [true, true],
                               selectionBoosts: [0, 0], autoSelectEnabled: true).autoSelected,
  0, "a partial match never displaces an exact match")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [100, 100], languageRanks: [1, 0], canAutomaticallySelect: [false, false],
                               selectionBoosts: [0, 0], autoSelectEnabled: true).autoSelected,
  nil, "a provider that has not opted in is never selected automatically")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [100, 100], languageRanks: [1, 0], canAutomaticallySelect: [true, true],
                               selectionBoosts: [0, 0], autoSelectEnabled: false).autoSelected,
  nil, "the setting turns automatic selection off")

section("preselection")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [90, 90], languageRanks: [1, 0], canAutomaticallySelect: [false, false],
                               selectionBoosts: [0, 0], autoSelectEnabled: true).preselected,
  1, "the preferred language breaks a score tie")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [90, 60], languageRanks: [nil, 0], canAutomaticallySelect: [false, false],
                               selectionBoosts: [0, 0], autoSelectEnabled: true).preselected,
  0, "a much stronger title match outranks a weaker preferred-language result")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [60, 90], languageRanks: [0, nil], canAutomaticallySelect: [false, false],
                               selectionBoosts: [0, 0], autoSelectEnabled: true).preselected,
  1, "a stronger title match can outrank a weaker preferred-language result")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [50, 90], languageRanks: [nil, nil], canAutomaticallySelect: [false, false],
                               selectionBoosts: [0, 0], autoSelectEnabled: true).preselected,
  1, "without languages the highest score is still selected")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [50, 50], languageRanks: [nil, nil], canAutomaticallySelect: [false, false],
                               selectionBoosts: [0, 0], autoSelectEnabled: true).preselected,
  0, "an unresolvable tie keeps the provider's first result")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [0, 0], languageRanks: [0, 1], canAutomaticallySelect: [false, false],
                               selectionBoosts: [0, 0], autoSelectEnabled: true).preselected,
  nil, "a preferred language alone preselects nothing that does not resemble the media")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [0, 0], languageRanks: [nil, nil], canAutomaticallySelect: [false, false],
                               selectionBoosts: [0, 1000], autoSelectEnabled: true).preselected,
  1, "provider evidence preselects without a name score")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [100], languageRanks: [nil], canAutomaticallySelect: [true],
                               selectionBoosts: [0], autoSelectEnabled: true),
  SubtitleSelectionPlan(autoSelected: 0, preselected: 0), "the selected result is also the preselection")

section("malformed input decides nothing")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [], languageRanks: [], canAutomaticallySelect: [],
                               selectionBoosts: [], autoSelectEnabled: true),
  SubtitleSelectionPlan(autoSelected: nil, preselected: nil), "no results")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [100, 100], languageRanks: [0], canAutomaticallySelect: [true, true],
                               selectionBoosts: [0, 0], autoSelectEnabled: true),
  SubtitleSelectionPlan(autoSelected: nil, preselected: nil), "mismatched language ranks")

expectEqual(
  SubtitleSelectionPlan.decide(scores: [100], languageRanks: [0], canAutomaticallySelect: [true],
                               selectionBoosts: [], autoSelectEnabled: true),
  SubtitleSelectionPlan(autoSelected: nil, preselected: nil), "missing boosts")

print("\n\(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)") — \(total) checks")
exit(failures == 0 ? 0 : 1)
