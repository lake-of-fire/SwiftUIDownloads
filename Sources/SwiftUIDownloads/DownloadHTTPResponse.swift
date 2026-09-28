// Forked from: https://github.com/yukonblue/URLResourceKit/blob/0dda2eadcdf2ccf8323280bb4b3f5a430972134e/Sources/URLResourceKit/URLResourceDownloadTask.swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private func makeRetryAfterDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
}

func parseHTTPDate(_ value: String) -> Date? {
    makeRetryAfterDateFormatter().date(
        from: value.trimmingCharacters(in: .whitespacesAndNewlines)
    )
}

private func validatedRetryAfterSeconds(_ seconds: Double) -> Double? {
    seconds.isFinite && seconds >= 0 ? seconds : nil
}

func parseRetryAfterSeconds(_ value: String, now: Date = Date()) -> Double? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let deltaSeconds = Double(trimmed) {
        return validatedRetryAfterSeconds(deltaSeconds)
    }
    if let retryDate = makeRetryAfterDateFormatter().date(from: trimmed) {
        return validatedRetryAfterSeconds(max(0, retryDate.timeIntervalSince(now)))
    }
    return nil
}

func retryAfterSeconds(from response: HTTPURLResponse, now: Date = Date()) -> Double? {
    if let headerValue = response.value(forHTTPHeaderField: "Retry-After") {
        return parseRetryAfterSeconds(headerValue, now: now)
    }
    return nil
}

public struct URLResourceDownloadHTTPError: LocalizedError, Sendable {
    public let statusCode: Int
    public let url: URL?
    public let retryAfterSeconds: Double?

    public init(statusCode: Int, url: URL?, retryAfterSeconds: Double? = nil) {
        self.statusCode = statusCode
        self.url = url
        self.retryAfterSeconds = retryAfterSeconds.flatMap(validatedRetryAfterSeconds)
    }

    public var errorDescription: String? {
        let status = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        var description = "HTTP \(statusCode) (\(status))"
        if let url {
            description += " for \(url.absoluteString)"
        }
        if let retryAfterSeconds {
            let seconds = retryAfterSeconds.rounded(.towardZero)
            let formattedSeconds = Int(exactly: seconds).map(String.init) ?? String(seconds)
            description += ", Retry-After \(formattedSeconds)s"
        }
        return description
    }
}

enum DownloadResponseAdmissionError: LocalizedError {
    case unexpectedPartialResponse(URL?)

    var errorDescription: String? {
        switch self {
        case .unexpectedPartialResponse(let url):
            return "A partial response cannot be installed as a complete download"
                + (url.map { " for \($0.absoluteString)" } ?? "") + "."
        }
    }
}

/// This transport makes unconditional whole-file GETs. It neither requests
/// ranges nor assembles them, so a partial response cannot authorize delivery.
func downloadResponseAdmissionError(
    response: URLResponse?,
    requestedURL: URL
) -> (any Error)? {
    guard let response else { return URLError(.badServerResponse) }
    guard let httpResponse = response as? HTTPURLResponse else {
        let scheme = requestedURL.scheme?.lowercased()
        return scheme == "http" || scheme == "https" ? URLError(.badServerResponse) : nil
    }
    guard (200...299).contains(httpResponse.statusCode), httpResponse.statusCode != 206 else {
        return URLResourceDownloadHTTPError(
            statusCode: httpResponse.statusCode,
            url: requestedURL,
            retryAfterSeconds: retryAfterSeconds(from: httpResponse)
        )
    }
    // Do not accept a mislabeled range envelope as ordinary file bytes either.
    if httpResponse.value(forHTTPHeaderField: "Content-Range") != nil
        || httpResponse.mimeType?.lowercased() == "multipart/byteranges" {
        return DownloadResponseAdmissionError.unexpectedPartialResponse(response.url)
    }
    return nil
}
