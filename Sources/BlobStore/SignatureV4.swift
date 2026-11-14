public import Foundation

/// AWS Signature Version 4, for S3 requests.
///
/// Written directly rather than pulling in an AWS SDK: the S3 surface a service
/// needs is four verbs, and SigV4 is a stable, well-specified algorithm. Needing
/// multipart upload, a retry policy or credential-provider chains would flip
/// that trade in favour of a real SDK.
public struct SignatureV4: Sendable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let sessionToken: String?
    public let region: String
    public let service: String

    public init(
        accessKeyID: String,
        secretAccessKey: String,
        sessionToken: String? = nil,
        region: String,
        service: String
    ) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.region = region
        self.service = service
    }

    /// Signs a request, returning the headers to send.
    ///
    /// `headers` must already contain `host`. The payload hash is always sent as
    /// `x-amz-content-sha256`, which S3 requires and which also lets the server
    /// reject a body that was altered in transit.
    public func sign(
        method: String,
        url: URL,
        headers: [String: String],
        payload: Data,
        date: Date = Date()
    ) -> [String: String] {
        let timestamp = date.formatted(Self.timestampFormat)
        let day = String(timestamp.prefix(8))
        let payloadHash = SHA256Digest.hex(of: payload)

        var signed = headers
        signed["x-amz-date"] = timestamp
        signed["x-amz-content-sha256"] = payloadHash
        if let sessionToken {
            signed["x-amz-security-token"] = sessionToken
        }

        // Canonical headers: lowercase names, trimmed values, sorted by name.
        let canonicalHeaderNames = signed.keys
            .map { $0.lowercased() }
            .sorted()
        let canonicalHeaders = canonicalHeaderNames
            .map { name in
                let value = signed.first { $0.key.lowercased() == name }?.value ?? ""
                return "\(name):\(value.trimmingCharacters(in: .whitespaces))\n"
            }
            .joined()
        let signedHeaders = canonicalHeaderNames.joined(separator: ";")

        let canonicalRequest = [
            method,
            Self.canonicalURI(url),
            Self.canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            scope,
            SHA256Digest.hex(of: Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signature = Self.hex(signingKey(day: day, stringToSign: stringToSign))

        signed["Authorization"] = "AWS4-HMAC-SHA256 "
            + "Credential=\(accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaders), "
            + "Signature=\(signature)"
        return signed
    }

    private func signingKey(day: String, stringToSign: String) -> Data {
        var key = Data("AWS4\(secretAccessKey)".utf8)
        for component in [day, region, service, "aws4_request"] {
            key = SHA256Digest.hmac(key: key, data: Data(component.utf8))
        }
        return SHA256Digest.hmac(key: key, data: Data(stringToSign.utf8))
    }

    /// The path, percent-encoded per RFC 3986 with `/` preserved.
    ///
    /// S3 keys can contain characters that URL-encode differently in the two
    /// halves of the request, and a mismatch produces a signature error that
    /// says nothing useful — so both sides derive from this one function.
    static func canonicalURI(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty else { return "/" }
        return path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(String($0)) }
            .joined(separator: "/")
    }

    static func canonicalQuery(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              !items.isEmpty else {
            return ""
        }
        var encoded: [(name: String, value: String)] = []
        encoded.reserveCapacity(items.count)
        for item in items {
            encoded.append((name: encode(item.name), value: encode(item.value ?? "")))
        }
        encoded.sort { left, right in
            left.name == right.name ? left.value < right.value : left.name < right.name
        }
        return encoded.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    /// RFC 3986 unreserved characters stay; everything else is percent-encoded
    /// uppercase. `Foundation`'s own escaping does not match what SigV4 expects.
    static func encode(_ value: String) -> String {
        var result = ""
        for byte in Array(value.utf8) {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
                result.append(Character(UnicodeScalar(byte)))
            default:
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// `yyyyMMdd'T'HHmmss'Z'` in UTC, as SigV4 requires.
    static let timestampFormat = Date.ISO8601FormatStyle(
        dateSeparator: .omitted, dateTimeSeparator: .standard, timeSeparator: .omitted, timeZone: .gmt
    )
}
