import Foundation

let acceptedTrue = ["yes", "YES", "true", " True ", "1", "on"]
let acceptedFalse = ["no", "NO", "false", " False ", "0", "off"]
for value in acceptedTrue {
  guard CommandLineBoolean.parse(value) == true else {
    fputs("FAIL: expected true for \(value)\n", stderr)
    exit(1)
  }
}
for value in acceptedFalse {
  guard CommandLineBoolean.parse(value) == false else {
    fputs("FAIL: expected false for \(value)\n", stderr)
    exit(1)
  }
}
for value in ["", "typo", "2", "maybe"] {
  guard CommandLineBoolean.parse(value) == nil else {
    fputs("FAIL: expected invalid for \(value)\n", stderr)
    exit(1)
  }
}
guard let emptyHeadless = CommandLineBoolean.option("--headless="),
      emptyHeadless.name == "headless", emptyHeadless.value == "" else {
  fputs("FAIL: empty boolean values must remain distinguishable from bare flags\n", stderr)
  exit(1)
}
guard let invalidNoMute = CommandLineBoolean.option("--no-mute=garbage"),
      invalidNoMute.name == "no-mute", invalidNoMute.value == "garbage" else {
  fputs("FAIL: option tokenization must preserve inverse-flag values\n", stderr)
  exit(1)
}
print("PASS: command-line boolean parsing rejects unknown values")
