import Foundation

enum BoundedNetworkError: Error, Equatable {
    case insecureURL
    case redirectRejected
    case invalidResponse
    case invalidContentLength
    case responseTooLarge
    case bodyTooLarge
}

enum BoundedNetworkPolicy {
    static func isSecureHTTPSURL(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https" && url?.host?.isEmpty == false
    }

    static func declaredContentLength(_ response: HTTPURLResponse) throws -> Int64? {
        guard let rawValue = response.value(forHTTPHeaderField: "Content-Length") else {
            return nil
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let length = Int64(value),
              length >= 0
        else {
            throw BoundedNetworkError.invalidContentLength
        }
        return length
    }

    static func validateResponse(
        _ response: HTTPURLResponse,
        maximumBytes: Int64
    ) throws -> Int64? {
        guard maximumBytes > 0,
              isSecureHTTPSURL(response.url)
        else {
            throw BoundedNetworkError.insecureURL
        }
        let contentLength = try declaredContentLength(response)
        if let contentLength, contentLength > maximumBytes {
            throw BoundedNetworkError.responseTooLarge
        }
        return contentLength
    }

    static func rejectRedirect() throws -> Never {
        throw BoundedNetworkError.redirectRejected
    }

    static func ephemeralConfiguration(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }
}

struct BoundedBodyAccumulator {
    let maximumBytes: Int
    private(set) var data = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    mutating func append(_ chunk: Data) throws {
        guard maximumBytes > 0,
              data.count <= maximumBytes,
              chunk.count <= maximumBytes - data.count
        else {
            throw BoundedNetworkError.bodyTooLarge
        }
        data.append(chunk)
    }
}

final class BoundedDataLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let configuration: URLSessionConfiguration
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var accumulator: BoundedBodyAccumulator
    private var terminalError: Error?

    init(maximumBytes: Int, configuration: URLSessionConfiguration) {
        self.maximumBytes = maximumBytes
        self.configuration = configuration
        accumulator = BoundedBodyAccumulator(maximumBytes: maximumBytes)
    }

    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard BoundedNetworkPolicy.isSecureHTTPSURL(request.url), maximumBytes > 0 else {
            throw BoundedNetworkError.insecureURL
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            accumulator = BoundedBodyAccumulator(maximumBytes: maximumBytes)
            response = nil
            terminalError = nil
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        do {
            try BoundedNetworkPolicy.rejectRedirect()
        } catch {
            terminalError = error
        }
        completionHandler(nil)
        task.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            terminalError = BoundedNetworkError.invalidResponse
            completionHandler(.cancel)
            return
        }
        do {
            _ = try BoundedNetworkPolicy.validateResponse(http, maximumBytes: Int64(maximumBytes))
            self.response = http
            completionHandler(.allow)
        } catch {
            terminalError = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard terminalError == nil else { return }
        do {
            try accumulator.append(data)
        } catch {
            terminalError = error
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let terminalError {
            finish(.failure(terminalError))
        } else if let error {
            finish(.failure(error))
        } else if let response {
            finish(.success((accumulator.data, response)))
        } else {
            finish(.failure(BoundedNetworkError.invalidResponse))
        }
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session?.invalidateAndCancel()
        session = nil
        continuation.resume(with: result)
    }
}
