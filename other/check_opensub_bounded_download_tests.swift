import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class BoundedDownloadURLProtocol: URLProtocol {
  enum Plan {
    case response(status: Int, headers: [String: String], chunks: [Data])
    case waitForCancellation
    case redirect(URL)
  }

  private static let lock = NSLock()
  private static var responder: ((URLRequest) -> Plan)!
  private static var requestPaths: [String] = []
  private let cancellationLock = NSLock()
  private let released = DispatchSemaphore(value: 0)
  private var cancelled = false

  static func configure(_ makePlan: @escaping (URLRequest) -> Plan) {
    lock.lock()
    responder = makePlan
    requestPaths.removeAll()
    lock.unlock()
  }

  static var paths: [String] {
    lock.lock()
    defer { lock.unlock() }
    return requestPaths
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    let makePlan = Self.responder
    Self.requestPaths.append(request.url?.path ?? "")
    Self.lock.unlock()
    guard let makePlan else { return }

    switch makePlan(request) {
    case .response(let status, let headers, let chunks):
      sendResponse(status: status, headers: headers)
      for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
      client?.urlProtocolDidFinishLoading(self)
    case .waitForCancellation:
      sendResponse(status: 200, headers: [:])
      _ = released.wait(timeout: .now() + 5)
      cancellationLock.lock()
      let wasCancelled = cancelled
      cancellationLock.unlock()
      if !wasCancelled {
        client?.urlProtocol(self, didLoad: Data([1]))
        client?.urlProtocolDidFinishLoading(self)
      }
    case .redirect(let destination):
      guard let currentURL = request.url,
            let redirect = HTTPURLResponse(url: currentURL,
                                           statusCode: 302,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": destination.absoluteString]) else {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        return
      }
      client?.urlProtocol(self,
                          wasRedirectedTo: URLRequest(url: destination),
                          redirectResponse: redirect)
    }
  }

  override func stopLoading() {
    cancellationLock.lock()
    cancelled = true
    cancellationLock.unlock()
    released.signal()
  }

  private func sendResponse(status: Int, headers: [String: String]) {
    guard let url = request.url,
          let response = HTTPURLResponse(url: url,
                                         statusCode: status,
                                         httpVersion: "HTTP/1.1",
                                         headerFields: headers) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
  }
}

@main
struct OpenSubBoundedDownloadChecks {
  private static var checks = 0

  private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
      fputs("FAIL: \(message)\n", stderr)
      exit(1)
    }
  }

  private static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BoundedDownloadURLProtocol.self]
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }

  private static func execute(maximumBytes: Int,
                              cancellation: SubtitleAudioMatcher.Cancellation = .init(),
                              path: String = "/download") -> (Data?, URLResponse?, Error?, URLSessionTask?) {
    let completion = DispatchSemaphore(value: 0)
    let resultLock = NSLock()
    var result: (Data?, URLResponse?, Error?, URLSessionTask?) = (nil, nil, nil, nil)
    let session = makeSession()
    let helper = OpenSubBoundedDataTask(configuration: session.configuration,
                                        request: URLRequest(url: URL(string: "https://opensubtitles.com\(path)")!),
                                        maximumBytes: maximumBytes,
                                        cancellation: cancellation,
                                        identifier: UUID()) { data, response, error, task in
      resultLock.lock()
      result = (data, response, error, task)
      resultLock.unlock()
      completion.signal()
    }
    helper.start()
    guard completion.wait(timeout: .now() + 5) == .success else {
      fatalError("bounded URLSession transfer did not complete")
    }
    resultLock.lock()
    let completedResult = result
    resultLock.unlock()
    return completedResult
  }

  static func main() {
    BoundedDownloadURLProtocol.configure { _ in
      .response(status: 200, headers: ["Content-Type": "text/plain"], chunks: [Data([1, 2]), Data([3, 4, 5])])
    }
    let underLimit = execute(maximumBytes: 8)
    check(underLimit.0 == Data([1, 2, 3, 4, 5]) && underLimit.2 == nil,
          "a response without Content-Length is accumulated when it remains under the cap")

    BoundedDownloadURLProtocol.configure { _ in
      .response(status: 200, headers: [:], chunks: [Data([1, 2, 3, 4, 5]), Data([6, 7, 8, 9])])
    }
    let chunkedOverLimit = execute(maximumBytes: 8)
    check(chunkedOverLimit.0 == nil && chunkedOverLimit.2 is OpenSubResponseTooLargeError,
          "unknown-length chunked responses are rejected before retaining bytes above the cap")

    BoundedDownloadURLProtocol.configure { _ in
      .response(status: 200, headers: ["Content-Length": "1"], chunks: [Data(repeating: 9, count: 9)])
    }
    let dishonestLength = execute(maximumBytes: 8)
    check(dishonestLength.0 == nil && dishonestLength.2 is OpenSubResponseTooLargeError,
          "actual streamed bytes enforce the cap even when Content-Length is understated")

    BoundedDownloadURLProtocol.configure { _ in
      .response(status: 200, headers: ["Content-Length": "9"], chunks: [])
    }
    let declaredOverLimit = execute(maximumBytes: 8)
    check(declaredOverLimit.0 == nil && declaredOverLimit.2 is OpenSubResponseTooLargeError,
          "a declared over-limit response is rejected before body accumulation")

    let destination = URL(string: "https://opensubtitles.com/final")!
    BoundedDownloadURLProtocol.configure { request in
      request.url?.path == "/redirect"
        ? .redirect(destination)
        : .response(status: 200, headers: [:], chunks: [Data([7])])
    }
    let redirected = execute(maximumBytes: 8, path: "/redirect")
    check(redirected.0 == Data([7]) && BoundedDownloadURLProtocol.paths == ["/redirect", "/final"],
          "ordinary URLSession redirects still reach the bounded final response")

    let started = DispatchSemaphore(value: 0)
    BoundedDownloadURLProtocol.configure { _ in
      started.signal()
      return .waitForCancellation
    }
    let cancellation = SubtitleAudioMatcher.Cancellation()
    let cancellationDone = DispatchSemaphore(value: 0)
    var cancellationError: Error?
    let session = makeSession()
    OpenSubBoundedDataTask(configuration: session.configuration,
                           request: URLRequest(url: URL(string: "https://opensubtitles.com/cancel")!),
                           maximumBytes: 8,
                           cancellation: cancellation,
                           identifier: UUID()) { _, _, error, _ in
      cancellationError = error
      cancellationDone.signal()
    }.start()
    check(started.wait(timeout: .now() + 5) == .success,
          "cancellable response starts locally")
    cancellation.cancel()
    check(cancellationDone.wait(timeout: .now() + 5) == .success && cancellationError != nil,
          "cancellation interrupts an in-flight streamed response")

    print("\(checks) OpenSub bounded-download checks passed")
  }
}
