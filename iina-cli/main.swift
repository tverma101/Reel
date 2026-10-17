//
//  main.swift
//  iina-cli
//
//  Created by Collider LI on 6/12/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Foundation

guard var execURL = Bundle.main.executableURL else {
  print("Cannot get executable path.")
  exit(1)
}

let currentDirURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

execURL.resolveSymlinksInPath()

let processInfo = ProcessInfo.processInfo

let appBundleURL = execURL.deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
let appExecutableName = Bundle(url: appBundleURL)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
let candidateExecutableNames = [appExecutableName, "IINA", "Reel"].compactMap { $0 }
let appExecutableURL = candidateExecutableNames
  .map { execURL.deletingLastPathComponent().appendingPathComponent($0) }
  .first { FileManager.default.isExecutableFile(atPath: $0.path) }

guard let appExecutableURL else {
  print("Cannot find the player binary. This command line tool only works in the player app bundle.")
  exit(1)
}

let iinaPath = appExecutableURL.path

let task = Process()
task.launchPath = iinaPath

var keepRunning = false

// Check arguments

var userArgs = Array(processInfo.arguments.dropFirst())

if userArgs.contains(where: { $0 == "--help" || $0 == "-h" }) {
  print(
    """
    Usage: iina-cli [arguments] [files] [-- mpv_option [...]]

    Arguments:
    --mpv-*:
            All mpv options are supported here, except those starting with "--no-".
            Example: --mpv-volume=20 --mpv-resume-playback=no
    --separate-windows | -w:
            Open all files in separate windows.
    --stdin, --no-stdin:
            You may also pipe to stdin directly. Sometimes iina-cli can detect whether
            stdin has file, but sometimes not. Therefore it's recommended to always
            supply --stdin when piping to iina, and --no-stdin when you are not intend
            to use stdin.
    --keep-running:
            Normally iina-cli launches IINA and quits immediately. Supply this option
            if you would like to keep it running until the main application exits.
    --music-mode:
            Enter music mode after opening the media.
    --pip:
            Enter Picture-in-Picture after opening the media. Music mode does not
            support Picture-in-Picture.
    --headless:
            Load media without presenting playback windows or activating IINA. Audio is
            muted automatically. Use for background diagnostics and batch processing.
            Boolean values accept yes/no, true/false, on/off, or 1/0.
    --mute | --no-mute:
            Mute or unmute audio without changing window behavior. --headless always mutes.
    --help | -h:
            Print this message.

    mpv Option:
    Raw mpv options without --mpv- prefix. All mpv options are supported here.
    Example: --volume=20 --no-resume-playback
    """)
  exit(0)
}

let optionArguments = Array(userArgs.prefix(while: { $0 != "--" }))
let separatorIndex = userArgs.firstIndex(of: "--")
let literalArguments = separatorIndex.map { Array(userArgs.dropFirst($0 + 1)) } ?? []

func validateBooleanOptions(_ arguments: [String]) {
  for argument in arguments.prefix(while: { $0 != "--" }) {
    let option: String
    let value: String?
    if let separator = argument.firstIndex(of: "=") {
      option = String(argument[..<separator])
      value = String(argument[argument.index(after: separator)...])
    } else {
      option = argument
      value = nil
    }
    guard ["--headless", "--mute", "--no-mute"].contains(option) else { continue }
    if option == "--no-mute" {
      if value == nil { continue }
      FileHandle.standardError.write(Data("Invalid boolean option: \(argument)\n".utf8))
      exit(EX_USAGE)
    }
    guard let value else { continue }
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "yes", "true", "1", "on", "no", "false", "0", "off": continue
    default:
      FileHandle.standardError.write(Data("Invalid boolean option: \(argument)\n".utf8))
      exit(EX_USAGE)
    }
  }
}

validateBooleanOptions(optionArguments)

let mediaArguments = (optionArguments + literalArguments).filter { !$0.hasPrefix("-") }
let fileArguments = mediaArguments.filter { !Regex.url.matches($0) }
let explicitlyUsesStdin = optionArguments.reduce(false) { usesStdin, argument in
  switch argument {
  case "--stdin", "--mpv--": return true
  case "--no-stdin": return false
  default: return usesStdin
  }
}
if !fileArguments.isEmpty && !explicitlyUsesStdin {
  for argument in fileArguments {
    let url = URL(fileURLWithPath: argument, relativeTo: currentDirURL).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else {
      FileHandle.standardError.write(Data("No such input file: \(argument)\n".utf8))
      exit(EX_NOINPUT)
    }
  }
}

if optionArguments.contains("--music-mode"), optionArguments.contains("--pip") {
  // Music mode does not support Picture-in-Picture. Combining these options is not permitted.
  print("Cannot specify both --music-mode and --pip")
  // Command line usage error.
  exit(EX_USAGE)
}

var isStdin = false
var userSpecifiedStdin = false

for arg in optionArguments {
  if arg == "--stdin" || arg == "--mpv--" {
    isStdin = true
    userSpecifiedStdin = true
  } else if arg == "--no-stdin" {
    isStdin = false
    userSpecifiedStdin = true
  } else if arg == "--" {
    break
  }
}

if (!userSpecifiedStdin) {
  guard let stdin = InputStream(fileAtPath: "/dev/stdin") else {
    print("Cannot open stdin.")
    exit(1)
  }
  stdin.open()
  isStdin = stdin.hasBytesAvailable
}

let requestsHeadless = optionArguments.reduce(false) { enabled, argument in
  guard let separator = argument.firstIndex(of: "=") else {
    return argument == "--headless" ? true : enabled
  }
  guard argument[..<separator] == "--headless" else { return enabled }
  switch String(argument[argument.index(after: separator)...])
    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
  case "yes", "true", "1", "on": return true
  case "no", "false", "0", "off": return false
  default: return enabled // Invalid values were rejected above.
  }
}
if requestsHeadless && mediaArguments.isEmpty && !isStdin {
  FileHandle.standardError.write(Data("Headless mode requires a media input or stdin.\n".utf8))
  exit(EX_USAGE)
}

if let dashIndex = userArgs.firstIndex(of: "--") {
  userArgs.remove(at: dashIndex)
  for i in dashIndex..<userArgs.count {
    let arg = userArgs[i]
    if arg.hasPrefix("--") {
      if arg.hasPrefix("--no-") {
        userArgs[i] = "--mpv-\(arg.dropFirst(5))=no"
      } else {
        userArgs[i] = "--mpv-\(arg.dropFirst(2))"
      }
    }
  }
}

userArgs = userArgs.map { arg in
  if !arg.hasPrefix("-"),
    !Regex.url.matches(arg),
    let encodedFilePath = arg.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
    let fileURL = URL(string: encodedFilePath, relativeTo: currentDirURL),
    FileManager.default.fileExists(atPath: fileURL.path) {
    return fileURL.path
  } else if arg == "-w" {
    return "--separate-windows"
  }
  if arg == "--keep-running" {
    keepRunning = true
  }
  return arg
}

// Handle stdin

if isStdin {
  task.standardInput = FileHandle.standardInput
  task.standardOutput = FileHandle.standardOutput
  if !userSpecifiedStdin {
    userArgs.insert("--stdin", at: 0)
  }
} else {
  task.standardOutput = nil
  task.standardError = nil
}

task.arguments = userArgs

func terminateTaskIfRunning() {
  if task.isRunning {
    task.terminate()
  }
}

[SIGTERM, SIGINT].forEach { sig in
  signal(sig) { _ in
    terminateTaskIfRunning()
    exit(1)
  }
}

atexit {
  if isStdin || keepRunning {
    terminateTaskIfRunning()
  }
}

task.launch()

if isStdin || keepRunning {
  task.waitUntilExit()
}
