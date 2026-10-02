//
//  check_subtitle_matcher_tests.swift
//  iina
//
//  Cases for `SubtitleMatchScorer`, run by `other/check_subtitle_matcher.sh`.
//
//  This file is concatenated after the extracted scorer enum and compiled as `main.swift`, so its
//  top level is the program entry point. It is not part of the app target.
//
//  The guiding rule: a score of 100 causes a subtitle to be downloaded and made active with no
//  prompt, so every case that is not obviously the same title must stay below 100. Cases marked
//  "must not be 100" assert exactly that and accept any sub-100 value, because their purpose is
//  safety, not ranking.
//

import Foundation

var failures = 0
var total = 0

func score(_ release: String?, _ media: String) -> Int {
  SubtitleMatchScorer.score(releaseName: release, mediaName: media)
}

func expect(_ release: String?, _ media: String, _ expected: Int, _ note: String = "") {
  total += 1
  let actual = score(release, media)
  if actual != expected {
    failures += 1
    print("FAIL  release=\(release ?? "nil") media=\(media) expected=\(expected) got=\(actual) \(note)")
  }
}

func expectNotPerfect(_ release: String?, _ media: String, _ note: String = "") {
  total += 1
  let actual = score(release, media)
  if actual >= 100 {
    failures += 1
    print("FAIL  release=\(release ?? "nil") media=\(media) scored \(actual), must be < 100 \(note)")
  }
}

func section(_ title: String) {
  print("\n--- \(title) ---")
}

section("must be 100: same title and same year or episode anchor")
expect("The.Matrix.1999.1080p.BluRay.x264-GROUP.srt", "The.Matrix.1999.1080p.BluRay.x264-GROUP", 100, "identical")
expect("The.Matrix.1999.1080p.BluRay.x264-GROUP.srt", "The.Matrix.1999.1080p", 100, "video carries extra tags")
expect("The.Matrix.1999.1080p.BluRay.x264-GROUP.ass", "The.Matrix.1999.1080p.BluRay.x264-GROUP", 100, ".ass extension")
expect("The.Matrix.1999.720p.srt", "The.Matrix.1999.1080p", 100, "different resolution, same title and year")
expect("The.Matrix.1999.1080p.WEB.HDR.DDP5.1.Atmos.H.265-NTb.srt", "The.Matrix.1999.2160p", 100, "modern tag soup")
expect("Amelie.2001.1080p.srt", "Amélie.2001.1080p", 100, "diacritics folded")
expect("Show.S01E02.1080p.WEB-DL.srt", "Show.S01E02", 100, "episode anchor")
expect("Show.S01E02.1080p.WEB-DL.DDP5.1.H.264-GRP.srt", "Show.S01E02.1080p", 100, "episode plus tags")
expect("Movie.2019.1080p.BluRay.x264.srt", "Movie.2019.1080p", 100, "short title")
expect("Sinners.2021.1080p.BluRay.x264-NTb.srt", "Sinners.2021.1080p", 100, "single common word plus year")

section("must not be 100: recombining S01 and E02 must not merge across a release tag")
expectNotPerfect("Show.S01.1080p.E02.WEB-DL.srt", "Show.S01E02", "season and episode split by a tag")
expectNotPerfect("Show.1080p.S01.E02.srt", "Show.S01E02", "title truncated before the marker")
expectNotPerfect("Show.S01E02.1080p.Flimflam.S01E07.720p.srt", "Show.S01E02", "wrong episode smuggled in after a tag")
expect("The.E2.Movie.2019.1080p.srt", "The.E2.Movie.2019.1080p", 100, "sanity: a title containing E2 is unaffected")

section("must be 100: episode marker spellings must agree")
expect("Show.S01E02.1080p.WEB-DL.srt", "Show.S01E02.1080p", 100, "season and episode run together")
expect("Show.S01.E02.1080p.WEB-DL.srt", "Show.S01.E02", 100, "dotted spelling on both sides")
expect("Show.S01.E02.1080p.WEB-DL.srt", "Show.S01E02", 100, "dotted release, joined media")
expect("Show.S01-E02.1080p.WEB-DL.srt", "Show.S01E02", 100, "hyphenated release, joined media")
expect("Show.S01E01E02.1080p.WEB-DL.srt", "Show.S01E01E02", 100, "multi-episode release")
expect("Show.1x02.1080p.WEB-DL.srt", "Show.1x02", 100, "numeric episode spelling")

section("must not be 100: the same episode under a different spelling is not the same anchor")
expectNotPerfect("Show.S01.E02.1080p.srt", "Show.S01E03", "dotted S01E02 vs S01E03")
expectNotPerfect("Show.S01E02.1080p.srt", "Show.S01E03", "wrong episode")
expectNotPerfect("Show.1x02.1080p.srt", "Show.S01E02", "1x02 vs S01E02, different schemes")
expectNotPerfect("Show.S01E01E02.1080p.srt", "Show.S01E01E03", "wrong multi-episode range")
expectNotPerfect("Show.S01E02.1080p.S01E07.720p.srt", "Show.S01E02", "wrong episode after a tag")

section("must not be 100: remakes — same title, different film, no attacker involved")
expectNotPerfect("The.Thing.2011.1080p.BluRay.x264-XXX.srt", "The.Thing.1982.1080p.BluRay.x264", "remake vs original")
expectNotPerfect("The.Mummy.2017.1080p.srt", "The.Mummy.1999.1080p", "remake")
expectNotPerfect("Suspiria.2018.1080p.srt", "Suspiria.1977.1080p", "remake")
expectNotPerfect("Westworld.2016.1080p.WEB-DL.srt", "Westworld.1973.1080p", "film vs series")
expectNotPerfect("Nosferatu.2024.1080p.srt", "Nosferatu.1922.1080p", "remake")
expectNotPerfect("Dune.2021.2160p.srt", "Dune.1984.1080p", "remake")
expectNotPerfect("The.Man.from.U.N.C.L.E..2015.1080p.srt", "The.Man.from.U.N.C.L.E..1964.1080p", "remake")

section("must not be 100: tag injection — the release name is chosen by the uploader")
expectNotPerfect("The.Matrix.1999.1080p.Sinners.2021.1080p.srt", "The.Matrix.1999.1080p", "extra year smuggled in")
expectNotPerfect("The.Matrix.1999.1080p.Sinners.2003.1080p.srt", "The.Matrix.1999.1080p", "second year")
expectNotPerfect("Dune.2160p.Part.Two.2024.2160p.WEB-DL.srt", "Dune.2021.2160p.WEB-DL.DDP5.1.HDR.HEVC-NTb", "sequel hidden after a tag")
expectNotPerfect("Show.S01E02.1080p.S01E07.720p.WEB-DL.srt", "Show.S01E02", "wrong episode after a tag")
expectNotPerfect("S.h.o.w.S01E02.2160p.Entirely.Other.Series.S01E09.1080p.srt", "Show.S01E02", "wrong show after a tag")
expectNotPerfect("The.Matrix.1080p.Sinners.srt", "The.Matrix.1999.1080p", "anchor omitted entirely")
expectNotPerfect("Sinners.2021.1080p.The.Matrix.srt", "The.Matrix.1999.1080p", "anchor belongs to another film")

section("must not be 100: word boundaries are significant")
expectNotPerfect("t.hematrix.1080p.Zzq.Flimflam.2044.BluRay.x264-EVIL.srt", "The.Matrix.1999.1080p", "boundary shifted one char")
expectNotPerfect("Oldboy.2003.1080p.srt", "Old.Boy.2003.1080p", "Oldboy vs Old Boy")
expectNotPerfect("th\u{200B}ematrix.1999.1080p.srt", "The.Matrix.1999.1080p", "zero-width space")
expectNotPerfect("La.Vie.EnRose.2007.srt", "La Vie En Rose", "different token boundaries, and no anchor")

section("must not be 100: no anchor to corroborate the title")
expectNotPerfect("The.Matrix.1999.1080p.BluRay.x264-GROUP.srt", "The.Matrix", "video name has no year or episode")
expectNotPerfect("Dr.Strangelove.1964.1080p.srt", "Dr. Strangelove", "no year in video name")
expectNotPerfect("The.Matrix.srt", "1917.2019.1080p", "year-only media must not match everything")
expectNotPerfect("1917.2019.1080p.srt", "2001.1080p", "both titles are bare years")

section("must not be 100: different titles, and unusable input")
expectNotPerfect("Avengers.Endgame.2019.1080p.srt", "Avengers.2012.1080p", "sequel")
expectNotPerfect("The.Matrix.Resurrections.2003.srt", "The.Matrix.1999.1080p", "sequel")
expectNotPerfect("Completely.Different.Name.2001.srt", "The.Matrix.1999.1080p", "unrelated")
expectNotPerfect(nil, "The.Matrix.1999", "provider gave no release name")
expectNotPerfect("", "The.Matrix.1999", "empty release name")
expect("The.Matrix.1999.srt", "", 0, "empty media name")
expect("Movie.2019.srt", "Movie.2019", 100, "sanity: identical short name")

section("ranking: an exact match must outrank a remake, which must outrank unrelated results")
let candidates: [(release: String, media: String)] = [
  ("Unrelated.Film.2001.1080p.srt", "The.Matrix.1999.1080p"),
  ("The.Matrix.1999.1080p.srt", "The.Matrix.1999.1080p"),
  ("The.Matrix.2011.1080p.srt", "The.Matrix.1999.1080p"),
  ("Matrix.Reloaded.2003.srt", "The.Matrix.1999.1080p"),
]
let scores = candidates.map { (release: $0.release, value: score($0.release, $0.media)) }
for entry in scores { print(String(format: "  %3d  %@", entry.value, entry.release)) }

total += 1
if scores.max(by: { $0.value < $1.value })?.value != 100 {
  failures += 1
  print("FAIL  the highest score is not the exact match")
}

total += 1
let remakeScore = scores.first { $0.release.contains("2011") }!.value
let unrelatedScore = scores.first { $0.release.contains("Unrelated") }!.value
if remakeScore <= unrelatedScore {
  failures += 1
  print("FAIL  a remake did not outrank an unrelated result (\(remakeScore) vs \(unrelatedScore))")
}

section("pathological input must not crash or hang")
let hostile: [(label: String, release: String?, media: String)] = [
  ("1 MB name", String(repeating: "A", count: 1_000_000) + ".1999.srt", "The.Matrix.1999.1080p"),
  ("10k tokens", String(repeating: "ab ", count: 10_000) + "1999.srt", "The.Matrix.1999"),
  ("separators only", String(repeating: ".-_ ", count: 5_000), "The.Matrix.1999.1080p"),
  ("digits only", String(repeating: "9", count: 5_000), "The.Matrix.1999.1080p"),
  ("whitespace", "   \t\n  ", "The.Matrix.1999"),
  ("punctuation", "!@#$%^&*()", "The.Matrix.1999"),
  ("NUL and BOM", "\u{0}\u{FEFF}The.Matrix.1999.1080p", "The.Matrix.1999.1080p"),
  ("RTL override", "The.Matrix.1999.1080p\u{202E}sinners", "The.Matrix.1999.1080p"),
  ("combining marks", "The.Ma\u{0308}trix.1999.1080p", "The.Matrix.1999.1080p"),
]
for entry in hostile {
  let started = Date()
  let value = score(entry.release, entry.media)
  let millis = Date().timeIntervalSince(started) * 1000
  total += 1
  if millis > 500 {
    failures += 1
    print("FAIL  \(entry.label) took \(String(format: "%.0f", millis))ms (score \(value))")
  }
}

print("\n\(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)") — \(total) checks")
exit(failures == 0 ? 0 : 1)
