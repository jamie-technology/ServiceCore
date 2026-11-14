import AuthenticationCore
import Foundation
import Synchronization

/// Accounts' token behaviour, in memory, as in its OAuthController: a refresh
/// is a compare-and-set on the access token's generation. From the current
/// generation it issues the next token and the previous one stops working;
/// from the one before it returns the token already issued; anything else is
/// `stale_generation`.
final class FakeAccounts: AccountsOAuthClient {
    struct Grant {
        var accessToken: String
        var refreshToken: String
        var subject: String
        var scopes: [String]
        var generation: UInt64 = 0
        var accessExpired = false
        var revoked = false
    }

    enum Failure { case none, unavailable }

    private struct State {
        var grants: [Grant] = []
        var codes: [String: String] = [:]
        var refreshCalls = 0
        var tokensIssued = 0
        var failure = Failure.none
        var delay = Duration.zero
        var hold: Gate?
    }

    private let state = Mutex(State())

    /// Starts a session at accounts and returns its access token.
    func issue(subject: String = "account-1", scopes: [String] = ["user.read"]) -> String {
        let access = "access-\(UUID().uuidString)"
        state.withLock {
            $0.grants.append(Grant(accessToken: access, refreshToken: "refresh-\(UUID().uuidString)", subject: subject, scopes: scopes))
        }
        return access
    }

    func code(for subject: String) -> String {
        let code = "code-\(UUID().uuidString)"
        state.withLock { $0.codes[code] = subject }
        return code
    }

    func expire(_ accessToken: String) { update(accessToken) { $0.accessExpired = true } }
    func revoke(_ accessToken: String) { update(accessToken) { $0.revoked = true } }

    /// Calls to the refresh endpoint, including ones that returned an existing token.
    var refreshCalls: Int { state.withLock { $0.refreshCalls } }
    /// Tokens refreshes actually issued.
    var tokensIssued: Int { state.withLock { $0.tokensIssued } }

    func failRefreshes(_ failure: Failure) { state.withLock { $0.failure = failure } }
    func delayRefreshes(_ delay: Duration) { state.withLock { $0.delay = delay } }

    /// Holds the next refresh's response after accounts has acted on it, until
    /// the gate opens: a response stuck on the network.
    func holdNextRefreshResponse() -> Gate {
        let gate = Gate()
        state.withLock { $0.hold = gate }
        return gate
    }

    private func update(_ accessToken: String, _ change: (inout Grant) -> Void) {
        state.withLock { state in
            if let index = state.grants.firstIndex(where: { $0.accessToken == accessToken }) {
                change(&state.grants[index])
            }
        }
    }

    func introspect(accessToken: String) async throws -> TokenIntrospection {
        state.withLock { state in
            guard let grant = state.grants.first(where: { $0.accessToken == accessToken }),
                  !grant.accessExpired, !grant.revoked else { return .inactive }
            return TokenIntrospection(
                active: true, subject: grant.subject, scopes: grant.scopes, clientIdentifier: "test",
                generation: grant.generation
            )
        }
    }

    func refresh(refreshToken: String, expectedGeneration: UInt64) async throws -> TokenGrant {
        let delay = state.withLock { $0.delay }
        if delay > .zero { try await Task.sleep(for: delay) }
        let (result, hold): (Result<TokenGrant, AccountsOAuthError>, Gate?) = state.withLock { state in
            state.refreshCalls += 1
            let hold = state.hold
            state.hold = nil
            if state.failure == .unavailable { return (.failure(.unavailable("down")), hold) }
            guard let index = state.grants.firstIndex(where: { $0.refreshToken == refreshToken }),
                  !state.grants[index].revoked else {
                return (.failure(.rejected(code: "invalid_grant", description: nil)), hold)
            }
            var grant = state.grants[index]
            if expectedGeneration == grant.generation {
                grant.accessToken = "access-\(UUID().uuidString)"
                grant.generation += 1
                grant.accessExpired = false
                state.grants[index] = grant
                state.tokensIssued += 1
            } else if expectedGeneration + 1 != grant.generation {
                return (.failure(.rejected(code: "stale_generation", description: nil)), hold)
            }
            return (.success(TokenGrant(
                accessToken: grant.accessToken, expiresIn: 3600, refreshToken: grant.refreshToken,
                scopes: grant.scopes, generation: grant.generation
            )), hold)
        }
        if let hold {
            hold.reached.open()
            await hold.wait()
        }
        return try result.get()
    }

    func exchange(code: String, redirectURI: String?) async throws -> TokenGrant {
        guard let subject = state.withLock({ $0.codes.removeValue(forKey: code) }) else {
            throw AccountsOAuthError.rejected(code: "invalid_grant", description: nil)
        }
        let access = issue(subject: subject)
        let grant = state.withLock { $0.grants.first { $0.accessToken == access }! }
        return TokenGrant(accessToken: access, expiresIn: 3600, refreshToken: grant.refreshToken, scopes: grant.scopes, generation: 0)
    }
}

/// A held refresh response: `reached` opens once accounts has acted on the
/// refresh; the response is released with `open()`.
final class Gate: Sendable {
    let reached = Latch()
    private let release = Latch()

    func wait() async { await release.wait() }
    func open() { release.open() }
}

/// Opens once; everyone waiting on it, before or after, then proceeds.
final class Latch: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// A clock tests move by hand.
final class TestClock: Sendable {
    private let date: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        date = Mutex(start)
    }

    var now: Date { date.withLock { $0 } }
    func set(_ new: Date) { date.withLock { $0 = new } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 += seconds } }
}
