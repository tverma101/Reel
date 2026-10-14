//
//  JavascriptAPIUtils.swift
//  iina
//
//  Created by Collider LI on 2/3/2019.
//  Copyright © 2019 lhc. All rights reserved.
//

import Foundation
import JavaScriptCore

fileprivate func searchBinary(_ file: String, in url: URL) -> URL? {
  let url = url.appendingPathComponent(file)
  return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

fileprivate extension Process {
  var descriptionDict: [String: Any] {
    return [
      "status": terminationStatus
    ]
  }
}

private final class JavascriptPromiseCompletion {
  private let lock = NSLock()
  private var didSettle = false

  @discardableResult
  func settle(on queue: DispatchQueue, _ action: @escaping () -> Void) -> Bool {
    lock.lock()
    guard !didSettle else {
      lock.unlock()
      return false
    }
    didSettle = true
    lock.unlock()
    queue.async(execute: action)
    return true
  }
}

@objc protocol JavascriptAPIUtilsExportable: JSExport {
  func fileInPath(_ file: String) -> Bool
  func resolvePath(_ path: String) -> String?
  func exec(_ file: String, _ args_: Any, _ cwd: JSValue?, _ stdoutHook_: JSValue?, _ stderrHook_: JSValue?) -> JSValue?
  func execWithTimeout(_ file: String, _ args_: Any, _ timeoutSeconds: Double) -> JSValue?
  func ask(_ title: String) -> Bool
  func prompt(_ title: String) -> String?
  func chooseFile(_ title: String, _ options: [String: Any]) -> Any
  func keychainWrite(_ service: String, _ name: String, _ password: String) -> Any
  func keychainRead(_ service: String, _ name: String) -> Any
  func open(_ url: String) -> Bool
  func preferredLocalizations() -> Any
}

class JavascriptAPIUtils: JavascriptAPI, JavascriptAPIUtilsExportable {
  func keychainWrite(_ service: String, _ name: String, _ password: String) -> Any {
    if service.isEmpty {
      return false
    }
    let serviceName = "\(pluginInstance.plugin.identifier) - \(service)"
    do {
      try KeychainAccess.write(username: name, password: password, forService: .init(serviceName))
      return true
    } catch {
      return false
    }
  }
  
  func keychainRead(_ service: String, _ name: String) -> Any {
    if service.isEmpty {
      return false
    }
    let serviceName = "\(pluginInstance.plugin.identifier) - \(service)"
    do {
      let (_, result) = try KeychainAccess.read(username: name, forService: .init(serviceName))
      return result
    } catch {
      return false
    }
  }
  
  override func extraSetup() {
    context.evaluateScript("""
    iina.utils.ERROR_BINARY_NOT_FOUND = -1;
    iina.utils.ERROR_RUNTIME = -2;
    """)
  }

  func fileInPath(_ file: String) -> Bool {
    guard permitted(to: .accessFileSystem) else {
      return false
    }
    if file.isEmpty {
      return false
    }
    if let _ = searchBinary(file, in: Utility.binariesURL) ?? searchBinary(file, in: Utility.exeDirURL) {
      return true
    }
    if let path = parsePath(file, forceLocalPath: false).path {
      return FileManager.default.fileExists(atPath: path)
    }
    return false
  }

  func resolvePath(_ path: String) -> String? {
    guard permitted(to: .accessFileSystem) else {
      return nil
    }
    return parsePath(path).path
  }

  func exec(_ file: String, _ args_: Any, _ cwd: JSValue?, _ stdoutHook_: JSValue?, _ stderrHook_: JSValue?) -> JSValue? {
    execute(file, args_, cwd, stdoutHook_, stderrHook_, timeoutSeconds: nil)
  }

  func execWithTimeout(_ file: String, _ args_: Any, _ timeoutSeconds: Double) -> JSValue? {
    guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 86_400 else {
      throwError(withMessage: "The exec timeout must be between 0 and 86400 seconds")
      return nil
    }
    return execute(file, args_, nil, nil, nil, timeoutSeconds: timeoutSeconds)
  }

  private func execute(_ file: String,
                       _ args_: Any,
                       _ cwd: JSValue?,
                       _ stdoutHook_: JSValue?,
                       _ stderrHook_: JSValue?,
                       timeoutSeconds: TimeInterval?) -> JSValue? {
    guard permitted(to: .accessFileSystem) else {
      return nil
    }
    
    guard let args = args_ as? [String] else {
      throwError(withMessage: "The exec args parameter must be a string array")
      return nil
    }

    return createPromise { [unowned self] resolve, reject in
      var path = ""
      var args = args
      if !file.contains("/") {
        if let url = searchBinary(file, in: Utility.binariesURL) ?? searchBinary(file, in: Utility.exeDirURL) {
          // a binary included in IINA's bundle?
          if #available(macOS 13.0, *) {
            path = url.path(percentEncoded: false)
          } else {
            path = url.path
          }
        } else {
          // assume it's a system command
          let useBash = false
          if useBash {
            path = "/bin/bash"
            args.insert(file, at: 0)
            args = ["-c", args.map {
              $0.replacingOccurrences(of: " ", with: "\\ ")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\"", with: "\\\"")
            }.joined(separator: " ")]
          } else {
            args.insert(file, at: 0)
          }
        }
      } else {
        // it should be an existing file
        if file.first == "/" {
          // an absolute path?
          path = file
        } else {
          path = parsePath(file).path ?? ""
        }
        // make sure the file exists
        guard FileManager.default.fileExists(atPath: path) else {
          reject.call(withArguments: [-1, "Cannot find the binary \(file)"])
          return
        }
      }

      // If this binary belongs to the plugin but doesn't have exec permission, try fix it
      if !FileManager.default.isExecutableFile(atPath: path) && (
        path.hasPrefix(self.pluginInstance.plugin.dataURL.path) ||
        path.hasPrefix(self.pluginInstance.plugin.tmpURL.path)) {
        do {
          try FileManager.default.setAttributes([.posixPermissions: NSNumber(integerLiteral: 0o755)], ofItemAtPath: path)
        } catch {
          reject.call(withArguments: [-2, "The binary is not executable, and execute permission cannot be added"])
          return
        }
      }

      let pluginIdentifier = self.pluginInstance.plugin.identifier
      // AirPlay's long-lived `serve` process can occupy both ordinary permits
      // for its plugin. Reserve a separate, globally bounded lane only for the
      // bundled helper's timed `stop` command so it can always request teardown.
      let isAirPlayStopCommand = timeoutSeconds != nil &&
        pluginIdentifier == BundledAirPlayPluginManager.identifier &&
        URL(fileURLWithPath: path).lastPathComponent == "airplay-helper" &&
        args.first == "stop"
      let admission = BoundedProcessExecutionAdmission.shared
      let executionPermit = isAirPlayStopCommand
        ? admission.acquireLifecycleControl(forPluginIdentifier: pluginIdentifier)
        : admission.acquire(forPluginIdentifier: pluginIdentifier)
      guard let executionPermit else {
        reject.call(withArguments: [-3, "Too many plugin processes are already active for this plugin or application"])
        return
      }

      let (stdout, stderr) = (Pipe(), Pipe())
      let process = Process()
      process.environment = ["LC_ALL": "en_US.UTF-8"]
      process.launchPath = path
      process.arguments = args
      if let cwd, cwd.isString, let cwdPath = parsePath(cwd.toString()).path {
        process.currentDirectoryPath = cwdPath
      }
      process.standardOutput = stdout
      process.standardError = stderr

      let stdoutHook: JSValue? = stdoutHook_.flatMap { $0.isObject ? $0 : nil }
      let stderrHook: JSValue? = stderrHook_.flatMap { $0.isObject ? $0 : nil }
      // All JS hooks and Promise callbacks for this plugin share its serial JS
      // queue. Process waits use a separate bounded-concurrency queue below.
      let outputCallbackQueue = self.pluginInstance.queue
      let processWaitQueue = PluginProcessExecutionQueues.processWait
      let subsystem = self.pluginInstance.subsystem
      let completionQueue = self.pluginInstance.queue
      let outputGroup = DispatchGroup()
      let stdoutReader = ProcessOutputStreamReader(
        fileHandle: stdout.fileHandleForReading,
        completionGroup: outputGroup,
        callbackQueue: outputCallbackQueue) { output in
          stdoutHook?.call(withArguments: [output])
        }
      let stderrReader = ProcessOutputStreamReader(
        fileHandle: stderr.fileHandleForReading,
        completionGroup: outputGroup,
        callbackQueue: outputCallbackQueue) { output in
          stderrHook?.call(withArguments: [output])
        }
      stdoutReader.start()
      stderrReader.start()
      Logger.log("Executing \(path) \(args.joined(separator: " "))", subsystem: subsystem)
      do {
        try process.run()
      } catch {
        stdoutReader.stop(suppressPendingCallbacks: true)
        stderrReader.stop(suppressPendingCallbacks: true)
        outputGroup.notify(queue: processWaitQueue) {
          executionPermit.release()
        }
        reject.call(withArguments: ["Execution failed reporting: \(error.localizedDescription)"])
        return
      }

      let promiseCompletion = JavascriptPromiseCompletion()
      let timeoutDeadline = timeoutSeconds.map { DispatchTime.now() + $0 }
      let timeoutWork: BoundedProcessTimeoutToken? = timeoutDeadline.map { deadline in
        BoundedProcessTimeout.schedule(for: process, deadline: deadline) {
          guard let timeoutSeconds else { return }
          promiseCompletion.settle(on: completionQueue) {
            reject.call(withArguments: [-4, "Process timed out after \(timeoutSeconds) seconds"])
          }
        }
      }

      processWaitQueue.async {
        process.waitUntilExit()
        timeoutWork?.cancel()
        // Process exit does not guarantee either pipe has delivered EOF. Give
        // both readers and their hooks a bounded window to drain. Process
        // completion runs off the plugin JS queue so one long process cannot
        // block settlement of unrelated calls.
        let streamsReachedEOF = outputGroup.wait(timeout: .now() + .seconds(2)) == .success
        stdoutReader.stop(suppressPendingCallbacks: !streamsReachedEOF)
        stderrReader.stop(suppressPendingCallbacks: !streamsReachedEOF)
        if !streamsReachedEOF {
          Logger.log("Timed out draining plugin process output after 2 seconds", subsystem: subsystem)
          // Suppression makes callback completion independent from a hook
          // already inside JavaScript. Wait only for the pipe readers to finish
          // their nonblocking finalization before releasing their state.
          outputGroup.wait()
        }
        let result: [String: Any] = [
          "status": process.terminationStatus,
          "stdout": stdoutReader.text,
          "stderr": stderrReader.text
        ]
        // Snapshot output before queuing JS settlement. The resolver closure
        // retains only the bounded result and admission permit, never Process,
        // readers, or pipe handles. If an admitted hook never returns, JSCore
        // cannot safely be re-entered to settle its Promise; the process and
        // reader lifecycle still completes and total retained calls stay capped.
        let didQueueSettlement = promiseCompletion.settle(on: completionQueue) {
          defer { executionPermit.release() }
          resolve.call(withArguments: [result])
        }
        if !didQueueSettlement {
          completionQueue.async { executionPermit.release() }
        }
      }
    }
  }

  func ask(_ title: String) -> Bool {
    let panel = NSAlert()
    panel.messageText = title
    panel.addButton(withTitle: NSLocalizedString("general.ok", comment: "OK"))
    panel.addButton(withTitle: NSLocalizedString("general.cancel", comment: "Cancel"))
    return panel.runModal() == .alertFirstButtonReturn
  }

  func prompt(_ title: String) -> String? {
    let panel = NSAlert()
    panel.messageText = title
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 60))
    input.lineBreakMode = .byWordWrapping
    input.usesSingleLineMode = false
    panel.accessoryView = input
    panel.addButton(withTitle: NSLocalizedString("general.ok", comment: "OK"))
    panel.addButton(withTitle: NSLocalizedString("general.cancel", comment: "Cancel"))
    panel.window.initialFirstResponder = input
    if panel.runModal() == .alertFirstButtonReturn {
      return input.stringValue
    }
    return nil
  }

  func chooseFile(_ title: String, _ options: [String: Any]) -> Any {
    let chooseDir = options["chooseDir"] as? Bool ?? false
    let allowedFileTypes = options["allowedFileTypes"] as? [String]
    return createPromise { resolve, reject in
      Utility.quickOpenPanel(title: title, chooseDir: chooseDir, allowedFileTypes: allowedFileTypes) { result in
        resolve.call(withArguments: [result.path])
      }
    }
  }

  func open(_ url: String) -> Bool {
    // always open web links
    if let url = URL(string: url) {
      if url.scheme == "https" || url.scheme == "http" {
        NSWorkspace.shared.open(url)
        return true
      }
    }
    // might be a file path
    let (path, isLocal) = parsePath(url)
    guard let path else {
      log("utils.open: path cannot be found", level: .error)
      return false
    }
    let fileURL = URL(fileURLWithPath: path)
    if isLocal {
      NSWorkspace.shared.open(fileURL)
      return true
    }
    return whenPermitted(to: .accessFileSystem) {
      NSWorkspace.shared.open(fileURL)
      return true
    } ?? false
  }

  func preferredLocalizations() -> Any {
    return Bundle.main.preferredLocalizations
  }
}
