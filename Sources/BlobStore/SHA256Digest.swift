public import Foundation
import Crypto

public enum SHA256Digest {
    public static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func bytes(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}
