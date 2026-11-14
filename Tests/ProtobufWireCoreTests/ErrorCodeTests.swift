import HTTPTypes
import ProtobufWireCore
import SwiftProtobuf
import Testing

/// A service's own codes, as a Swift enum rather than a proto one.
enum MailErrorCode: Int32, ServiceErrorCode {
    case mailboxFull = 1
    case messageGone = 2
    case relayDown = 3

    static let domain = "dauntless.mail.v1"

    var category: WireErrorCode {
        switch self {
        case .mailboxFull: .resourceExhausted
        case .messageGone: .notFound
        case .relayDown: .unavailable
        }
    }

    var status: HTTPResponse.Status {
        self == .messageGone ? .gone : category.status
    }
}

@Suite struct ErrorCodeTests {
    @Test func standardCategoriesMapToStatuses() {
        #expect(WireErrorCode.invalidArgument.status == .badRequest)
        #expect(WireErrorCode.unauthenticated.status == .unauthorized)
        #expect(WireErrorCode.conflict.status == .conflict)
        #expect(WireErrorCode.alreadyExists.status == .conflict)
        #expect(WireErrorCode.leaseExpired.status == .preconditionFailed)
        #expect(WireErrorCode.cancelled.status.code == 499)
        #expect(WireErrorCode.internal.status == .internalServerError)
    }

    @Test func conflictIsNotRetryable() {
        #expect(!WireErrorCode.conflict.isRetryable)
        #expect(WireErrorCode.unavailable.isRetryable)
        #expect(StandardError.conflict("stale").detail.retryable == false)
    }

    @Test func statusesMapBackToCategories() {
        #expect(WireErrorCode(status: .notFound) == .notFound)
        #expect(WireErrorCode(status: .contentTooLarge) == .invalidArgument)
        #expect(WireErrorCode(status: .badGateway) == .unavailable)
        #expect(WireErrorCode(status: HTTPResponse.Status(code: 418)) == .internal)
    }

    @Test func standardErrorsCarryNoDomain() {
        let detail = StandardError.conflict("ref moved", expected: "a", actual: "b").detail
        #expect(detail.code == .conflict)
        #expect(detail.domain.isEmpty)
        #expect(detail.reason == 0)
        #expect(detail.metadata == ["expected": "a", "actual": "b"])
        #expect(detail.code(as: WireErrorCode.self) == .conflict)
        #expect(detail.code(as: MailErrorCode.self) == nil)
    }

    @Test func serviceCodesRefineACategory() throws {
        let error = ServiceError(MailErrorCode.messageGone, "message was deleted")
        #expect(error.status == .gone)
        #expect(!error.isRetryable)

        let detail = error.detail
        #expect(detail.code == .notFound)
        #expect(detail.domain == "dauntless.mail.v1")
        #expect(detail.reason == 2)

        // Through the wire and back.
        let decoded = try WireErrorDetail(serializedBytes: detail.serializedBytes() as [UInt8])
        #expect(decoded.code(as: MailErrorCode.self) == .messageGone)
        #expect(decoded.code(as: WireErrorCode.self) == .notFound)
    }

    @Test func retryabilityCanBeOverridden() {
        #expect(ServiceError(MailErrorCode.relayDown, "relay down").isRetryable)
        #expect(!ServiceError(MailErrorCode.relayDown, "relay down", retryable: false).detail.retryable)
    }

    @Test func retryAfterBecomesAHeader() {
        let error = StandardError.resourceExhausted("slow down", retryAfter: 30)
        #expect(error.responseHeaders[.retryAfter] == "30")
    }

    /// Fields 1-4 must stay byte-compatible with the ErrorDetail messages the
    /// services already send, so existing clients keep decoding them.
    @Test func wireLayoutMatchesExistingErrorDetail() throws {
        var detail = WireErrorDetail()
        detail.code = .notFound
        detail.message = "x"
        detail.retryable = true
        detail.metadata = ["k": "v"]
        let bytes: [UInt8] = try detail.serializedBytes()
        // field 1 varint 4, field 2 "x", field 3 true, field 4 map entry {k: v}
        #expect(bytes == [0x08, 0x04, 0x12, 0x01, 0x78, 0x18, 0x01, 0x22, 0x06, 0x0A, 0x01, 0x6B, 0x12, 0x01, 0x76])
    }
}
