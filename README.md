# ServiceCore

Shared plumbing for the Vapor 5 + FoundationDB services. It replaces the copies that had drifted apart across Issura, Aegis, Accounts, Automatio, CaledonianSleeper, DauntlessMail and Ideatum.

| Library | Replaces | Depends on |
|---|---|---|
| `FoundationDBCore` | `FoundationDBSupport.swift` (connection and tenant parts) in every service | FoundationDB, swift-configuration |
| `RecordStore` | `withRecordStore`, Ideatum's `PageBounds` / `page`, Accounts' version encoding | FoundationDBCore, FDBRecordLayer |
| `BlobStore` | `BlobStore/` in Aegis, DauntlessMail, Automatio and Ideatum Storage | Vapor (HTTP client only), swift-crypto |
| `ProtobufWireCore` | `ProtobufContent.swift` (Automatio, Ideatum ServiceKit), Aegis's `ProtobufReply` | Vapor, swift-protobuf |
| `AuthenticationCore` | new: sign-in through accounts, an authentication middleware, token refresh. Client libraries in `Clients/` | Vapor, ProtobufWireCore |
| `AuthenticationFoundationDB` | new: AuthenticationCore's sessions on the Record Layer | AuthenticationCore, RecordStore |

`FoundationDBCore` and `RecordStore` do not depend on Vapor, so a storage-engine target like `AegisStore` can use them without pulling in HTTP.

```swift
.package(path: "../ServiceCore"),   // or the git URL, by branch
// …
.product(name: "RecordStore", package: "ServiceCore"),
.product(name: "ProtobufWireCore", package: "ServiceCore"),
```

The FDB targets link with `-L/usr/local/lib -rpath /usr/local/lib` on macOS. SwiftPM only accepts those unsafe flags from a dependency pulled in by path or branch, not by version.

## service-init

Scaffolds a new service. The output is `vapor new <name> --branch vapor5` reproduced file for file, with the chosen libraries added:

```bash
swift run service-init Mailroom                                   # the plain Vapor 5 template
swift run service-init Mailroom --fdb=records --protobuf-wire-library --blob-store
swift run service-init Mailroom --fdb=kv -o ../Mailroom --service-core-path ../ServiceCore
swift run service-init Mailroom --fdb=records --authentication
```

| Option | Adds |
|---|---|
| `--fdb=kv` | `FoundationDBCore`, a `Services` struct built in `configure`, a `POST /visits` atomic counter, the FDB-enabled Dockerfile (Accounts') |
| `--fdb=records` | `RecordStore` instead: a `Greeting.proto` record, `Schema.swift` with a key registry, the SwiftProtobuf plugin |
| `--protobuf-wire-library` | a `WireModels` library product (swift-protobuf + plugin, `Hello.proto`), `ProtobufWireCore`, protobuf error middleware, a `HelloController` (VaporMacros) serving `POST /v1/hello`, and tests for its success and error paths |
| `--blob-store` | `BlobStore` from `STORAGE_BLOBS_*` config, `POST /blobs` and `GET /blobs/:digest`, a blobs volume in docker-compose |
| `--authentication` | sign-in through accounts: `AuthenticationCore`, an `AuthenticationController` (`authorization-url`, `sign-in`, `sign-out`, and an example authenticated `GET /v1/me`), `Authentication.proto` in `WireModels`, the `ACCOUNTS_*` configuration, and tests against a fake accounts. Turns on `--protobuf-wire-library`. Sessions go in `FoundationDBSessionStore` with `--fdb`, otherwise in memory (a warning says so) |

Generated services depend on ServiceCore by git URL, `https://github.com/jamie-technology/ServiceCore.git` on `main`, so they build anywhere, Docker included. ServiceCore and the FoundationDB bindings are public, so builds need no credentials. `--service-core-url` and `--service-core-branch` change that. `--service-core-path` uses a local checkout instead, for developing ServiceCore alongside a service. `--no-git` skips `git init`, and `--force` writes into a non-empty directory.

## FoundationDBCore

```swift
let connection = try await FoundationDBConnection.connect(
    defaultTenant: "aegis-storage", config: app.configReader
)
```

This reads `fdb.cluster.file` and `fdb.tenant` (`FDB_CLUSTER_FILE`, `FDB_TENANT`). It creates the tenant if it is missing. If the cluster is not ready yet it waits (Accounts' behaviour) instead of failing to boot. Pass `retryInterval: nil` to try once. `FDBErrorCodes` names the error codes worth matching on.

## RecordStore

```swift
let records = RecordDatabase(connection: connection, metaData: schema, path: "storage")

try await records.withStore { store in
    let page = try await store.page(query, bounds: PageBounds(
        requestedLimit: Int(request.page.limit), cursor: request.page.cursor, maximum: 500
    ))
    response.nextCursor = Data(page.cursor)
}
```

- `withStore` opens the store inside each transaction, so conflicts retry automatically.
- `PageBounds` clamps the client's limit to a maximum. A limit of 0 means the default, never everything. An empty cursor means the first page.
- `store.all(query, maximum:)` throws `TooManyRecords` instead of loading an unbounded result.
- `FDBRecordVersion.base64URLEncoded` / `init?(base64URLEncoded:)` turn a version into the opaque token clients send back. `store.load(_:primaryKey:expecting:)` is the read half of optimistic concurrency.
- `RecordStoreError.isConflict / isAlreadyExists / isNotFound` classify Record Layer failures.

## BlobStore

```swift
let blobs = try BlobBackend(config: app.configReader).makeStore(client: app.client)
let key = BlobKey(scope: scope, hex: SHA256Digest.hex(of: bytes), token: BlobKey.newToken())!
try await blobs.putVerified(key, bytes: bytes)
```

Configuration lives under `storage.blobs` (`STORAGE_BLOBS_BACKEND=filesystem|s3`, `…_ROOT`, `…_S3_ENDPOINT`, …). This is unchanged from Aegis and DauntlessMail. Pass `scope:` to read it from a different key.

`BlobKey.token` is now optional. Aegis, DauntlessMail and Ideatum keep using tokens, so a late delete can never reach a newer copy of the same content. Services that never delete blobs can leave the token out. The on-disk and S3 layout with a token is byte-for-byte what those services write today.

## ProtobufWireCore

### Routes: VaporMacros controllers (preferred)

**Write routes as VaporMacros `@Controller`s.** That's the house style, and `service-init` generates it. A controller keeps a group of routes, their dependencies and their middleware in one type, and `@AuthMiddleware` hands authenticated handlers their account as a parameter. The closure helpers further down still work, for a route or two defined inline.

```swift
import ProtobufWireCore
import Vapor
import VaporMacros          // .product(name: "VaporMacros", package: "vapor")
import WireModels

@Controller
struct NotesController {
    let store: NotesStore

    @POST("v1", "notes")
    func create(req: Request) async throws -> Protobuf<Notes_Note> {
        let request = try await req.protobuf(Notes_CreateNoteRequest.self)
        guard !request.title.isEmpty else { throw StandardError.invalidArgument("title is required") }
        return Protobuf(try await store.create(request), status: .created)
    }

    @GET("v1", "notes", UUID.self)
    func get(req: Request, id: UUID) async throws -> Notes_Note {    // a ProtobufResponseEncodable message
        guard let note = try await store.note(id) else { throw StandardError.notFound("no such note") }
        return note
    }
}

// configure.swift
app.useProtobufErrors(configuration: .notes)                 // once: errors and configuration for every route
try await app.register(collection: NotesController(store: services.store))
```

In a handler:

- **Read the body:** `try await req.protobuf(M.self)`. An empty body gives the default message, and one that doesn't decode throws `invalidArgument`.
- **Return a message:** wrap it as `Protobuf(message)`, optionally with `status:` and `headers:`. Or return it directly once it conforms to `ProtobufResponseEncodable`:

  ```swift
  public import ProtobufWireCore    // public: the conformance is on a public type
  public import WireModels

  extension Notes_Note: ProtobufResponseEncodable {}
  ```

  Swift can't make every generated message `ResponseEncodable` at once, so conform the ones your routes return. Under `InternalImportsByDefault` the file declaring the conformances needs the `public import`s shown. Put these conformances in the service, not in `WireModels`, so clients of `WireModels` don't pull in Vapor.
- **Fail:** throw. `StandardError.notFound(…)`, your own `ServiceError(code, …)`, anything. `useProtobufErrors` turns every error into an `ErrorDetail` body (mapping below).
- **Authenticate:** add `@AuthMiddleware(AuthenticatedAccount.self, using: …)` and an `account: AuthenticatedAccount` parameter (see [AuthenticationCore](#a-services-authentication-controller)).

**The configuration.** A service sets its `ProtobufWireConfiguration` (request-ID header, `translateError`) once, in `app.useProtobufErrors(configuration:)`. The middleware makes it `ProtobufWireConfiguration.current` for the length of each request, so `Protobuf`, `req.protobuf`, `req.requestID()`, `AuthenticationMiddleware` and every other helper use it without a handler naming it. Outside a request, `.current` is `.default`.

**Limits.** `@Controller` routes can't set a per-route `maxBodySize`, so the application's default applies. Use the closure helper below for a route that takes large bodies. A handler's first parameter must be named `req`, typed `Request`. That's VaporMacros' rule.

### Routes: closure helpers

```swift
app.protobuf("v1", "zones", "lookup") { (request: LookupZonesRequest, req) in
    try await store.lookupZones(request)          // → 200, protobuf body
}                                                 // throw → ErrorDetail body

app.protobufErrors(.get, "v1", "export", maxBodySize: "1mb") { req in … }   // any Response, protobuf errors

return try ProtobufResponse.success(message, headers: headers)   // inside a hand-written route
return ProtobufResponse.failure(error, requestID: id)
```

These handle errors themselves, so they work whatever middleware the application has. Their `configuration:` defaults to the request's.

### Calling other services

`clientResponse.protobuf(M.self)` decodes a reply, and throws `RemoteServiceError` with the decoded `ErrorDetail` on a non-2xx status. `clientRequest.setProtobuf(message)` sets a body.

### How errors map to responses

| Thrown | Sent |
|---|---|
| `ServiceError` / `StandardError`, or any `ProtobufErrorConvertible` | as is |
| protobuf decoding errors | 400 `invalidArgument` |
| `CancellationError` | 499 `cancelled` |
| Vapor `AbortError` | its own status, category derived from it |
| anything else | 500 `internal`, message `"internal error"`. The real error is only logged. |

`ProtobufWireConfiguration.translateError` runs first, so a service can map errors it owns, e.g. `RecordStoreError.versionMismatch` → `StandardError.conflict(...)`. The configuration also sets the request-ID header (default `X-Request-ID`; use `X-Ideatum-Request-ID` etc. to keep existing clients working).

### Extensible error codes

`Protos/error.proto` defines the standard `WireErrorCode` categories and `WireErrorDetail`. Fields 1–4 of `ErrorDetail` are wire-identical to `ideatum.v1.ErrorDetail` and `automatio_wire.ErrorDetail`, and the code numbering follows Ideatum's.

Services never add values to the standard enum. They define their own codes and map each one onto a category:

```swift
extension Aegis_V1_ErrorCode: ServiceErrorCode {          // a proto enum…
    public static let domain = "aegis.v1"
    public var category: WireErrorCode {
        switch self {
        case .zoneNotFound, .unknownItem: .notFound
        case .serverRecordChanged: .conflict
        default: .invalidArgument
        }
    }
}

enum MailErrorCode: Int32, ServiceErrorCode { … }         // …or a Swift enum

throw ServiceError(Aegis_V1_ErrorCode.zoneNotFound, "Zone 'x' does not exist")
```

On the wire the category goes in `code`, so any client can act on it. The service's own code goes in `domain` and `reason`. Clients read it back with `detail.code(as: Aegis_V1_ErrorCode.self)`. `status` and `isRetryable` default to the category's and can be overridden per code.

A service that already has its own error message (Aegis's `Error`, which carries `server_record`) can conform that error type to `ProtobufErrorConvertible`. The same helpers will then send it.

## AuthenticationCore

Services sign people in through accounts with OAuth (the authorisation-code flow). The service is a confidential client: it holds the client secret and the refresh tokens. Clients only ever hold an access token and its version.

Three pieces:

| | |
|---|---|
| `AuthenticationCore` | the server: sign-in, `AuthenticationMiddleware`, token refresh, the `SessionStore` protocol |
| `AuthenticationFoundationDB` | sessions on the Record Layer |
| `Clients/swift` (`AuthenticationClient`), `Clients/typescript` (`@servicecore/authentication-client`) | the client side: token storage and request retries. See [How clients work](#how-clients-work). |

### Setup

Register the service in accounts (Services → OAuth) and configure it:

| Key | Environment | |
|---|---|---|
| `accounts.client.identifier` | `ACCOUNTS_CLIENT_IDENTIFIER` | the OAuth client ID |
| `accounts.client.secret` | `ACCOUNTS_CLIENT_SECRET` | the client secret (read as a secret, never logged) |
| `accounts.frontend.url` | `ACCOUNTS_FRONTEND_URL` | accounts' web app, which serves `/authorize` |
| `accounts.api.url` | `ACCOUNTS_API_URL` | accounts' API, which serves `/token` and `/introspect` |

```swift
let accounts = try AccountsConfiguration(config: app.configReader)
let auth = AuthenticationService(
    configuration: accounts,
    client: app.client,
    store: FoundationDBSessionStore(connection: connection)   // or any SessionStore
)
```

Accounts must be recent enough to send `access_token_generation` (accounts `aec3d66` or later). Older versions are refused with `accountsUnavailable` and an error in the log.

### A service's authentication controller

AuthenticationCore doesn't register routes, because request and response shapes are the service's own. A service needs a sign-in route and a sign-out route. The one convention is that **sign-in returns the token in the `X-Updated-Access-Token` and `X-Updated-Access-Token-Version` headers** (`signIn.responseHeaders`), whatever the body. The client libraries store it from there, with the same code that stores refreshed tokens.

`service-init --authentication` generates this controller, with its protos and tests. Abridged (`Notes_*` stand for the service's own `WireModels` messages):

```swift
@Controller
struct AuthenticationController {
    let auth: AuthenticationService
    let accounts: AccountsConfiguration

    var authentication: AuthenticationMiddleware { AuthenticationMiddleware(service: auth) }

    @POST("v1", "auth", "sign-in")
    func signIn(req: Request) async throws -> Protobuf<Notes_SignInResponse> {
        let request = try await req.protobuf(Notes_SignInRequest.self)
        let session = try await auth.signIn(code: request.code, redirectURI: request.redirectUri)
        var response = Notes_SignInResponse()
        response.accountID = session.account.id
        return Protobuf(response, headers: session.responseHeaders)    // the token, in headers
    }

    @POST("v1", "auth", "sign-out")
    @AuthMiddleware(AuthenticatedAccount.self, using: { (controller: AuthenticationController) in controller.authentication })
    func signOut(req: Request, account: AuthenticatedAccount) async throws -> Protobuf<Notes_SignOutResponse> {
        try await auth.signOut(accessToken: account.accessToken)
        return Protobuf(Notes_SignOutResponse())
    }

    @GET("v1", "me")
    @AuthMiddleware(AuthenticatedAccount.self, using: { (controller: AuthenticationController) in controller.authentication })
    func me(req: Request, account: AuthenticatedAccount) async throws -> Protobuf<Notes_MeResponse> {
        var response = Notes_MeResponse()
        response.accountID = account.id
        return Protobuf(response)
    }
}
```

The generated one also has `POST /v1/auth/authorization-url`, which builds `accounts.authorizationURL(redirectURI:scopes:state:)` so clients don't need the client ID.

The flow:

1. The client opens the authorisation URL. The person signs in at accounts and approves, and accounts redirects to the redirect URI with `code` and `state`. Accounts only accepts `https` redirect URIs (plain `http` on loopback for development), so an app uses a universal link (or `ASWebAuthenticationSession` with an `https` callback), not a custom scheme.
2. The client checks `state` against the one it generated, and sends the code to `sign-in`. `auth.signIn` exchanges the code, starts a session holding the refresh token, and returns the access token and its version for the response headers.
3. `auth.signOut` deletes the session. Accounts has no revocation endpoint, so the access token itself keeps working until it expires (an hour at most).

### Authenticating requests

In a `@Controller`, with `@AuthMiddleware`:

```swift
@GET("v1", "notes")
@AuthMiddleware(AuthenticatedAccount.self, using: { (controller: NotesController) in
    AuthenticationMiddleware(service: controller.auth, requiredScopes: ["user.read"])
})
func list(req: Request, account: AuthenticatedAccount) async throws -> Protobuf<Notes_NoteList> {
    Protobuf(try await store.notes(owner: account.id))
}
```

Elsewhere, `app.grouped(AuthenticationMiddleware(service: auth))` and `try req.account` do the same.

Key a service's own per-account data on `account.id`, the account's identifier at accounts. Never key it on the access token: tokens are replaced at every refresh, but the account ID never changes.

Each request's token is checked with accounts' introspection endpoint. Options: `allowsAnonymous` lets requests without an `Authorization` header through. `renderError` controls how errors are rendered once a token has been refreshed (default: protobuf `ErrorDetail`).

**Browsers, cross-origin:** list `X-Updated-Access-Token`, `X-Updated-Access-Token-Version` and `X-Authentication-Error` in the CORS configuration's exposed headers (`Access-Control-Expose-Headers`). Otherwise the browser hides them from the client.

### Providing an API to other services (resource servers)

A service other services call (Groups, say) registers an **API** at accounts (Services → the service → API): a
resource identifier, its scopes, and an allow-list of the OAuth clients that may get tokens for it. Other services'
clients then get tokens *for this service's API* (RFC 8707), and it accepts them once it knows its identifier:

| Key | Environment | |
|---|---|---|
| `accounts.resource.identifier` | `ACCOUNTS_RESOURCE_IDENTIFIER` | the API's resource identifier, exactly as registered |

There are then three kinds of caller, and `try req.principal` (an `AuthenticatedPrincipal`) says which:

| Token | `req.principal` |
|---|---|
| from this service's own sign-in | `.account(…)`, `client == nil` |
| a person signed in through another service, for this API | `.account(…)`, `client` = that service's client ID |
| another service acting as itself (client credentials), for this API | `.service(…)` |

`principal.subject` is `account:<id>` or `service:<client>`: one namespace, so a service is never mistaken for a
person. A person acting through another service is still that person: apply *their* authority (narrowed by the
token's scopes), and record `client` beside them in audit logs.

Services acting as themselves only get in where a route says so:

```swift
@AuthMiddleware(AuthenticatedPrincipal.self, using: { (controller: GroupsController) in
    AuthenticationMiddleware(service: controller.auth, requiredScopes: ["groups.read"], acceptsServices: true)
})
func list(req: Request, principal: AuthenticatedPrincipal) async throws -> Protobuf<Groups_V1_GroupList> { … }
```

Everywhere else, `AuthenticationMiddleware` and `authenticate(accessToken:)` behave as before: people only
(`req.account` works for delegated people too). Tokens for any other API are refused, as is this service's own
client-credentials token.

### Token refresh

When introspection says a token is no longer active and it is its session's current token, the middleware refreshes the session and the request goes ahead as the new token. The response, error responses included, carries the new token in `X-Updated-Access-Token` and its version in `X-Updated-Access-Token-Version`.

**Refreshing is a compare-and-set, at accounts.** Each access token has a generation: 0 at sign-in, plus one per refresh. The service refreshes with `expected_generation` set to its session's generation:

- From the current generation, accounts issues the next token.
- From the generation before the current one, accounts returns the token already issued.
- Anything older gets `stale_generation`.

So any number of requests refreshing the same token, at the same time or late, all get the same successor, and none invalidates a token another was just handed. There are no locks or leases. Concurrent refreshes at accounts conflict in FoundationDB, so exactly one commits.

**The session only moves forwards.** Sessions are keyed by a session ID. A refresh moves the session to the new token's digest and generation with a compare-and-swap, and never to a lower generation. If a refresh's response arrives after a later refresh has been recorded, it changes nothing.

**Old tokens are refused.** Once the session has moved on, the old token finds no session and gets `invalidAccessToken`. Nobody keeps a list of old tokens. The service only knows each session's current token, and the client only keeps its newest one.

**Versions order tokens across sign-ins.** The generation starts again at 0 with each sign-in, so clients order tokens by `AccessTokenVersion`, which is `<signedInAt ms>.<generation>`. A token from a later sign-in always outranks every token from an earlier one.

**What's still lost:** if the response carrying a new token never reaches the client (a dropped connection, a process killed mid-request), the client is left with a dead token and has to sign in again. Avoiding that would mean letting an old token fetch its successor, which this library deliberately doesn't allow. The client rules below make sure a response that is merely *late* doesn't cause a sign-out.

### How clients work

A client sends only `Authorization: Bearer <token>`. It never sends the version, because the service knows each session's generation itself. The rules:

1. **Store the token with its version.** Write a token from `X-Updated-Access-Token` (sign-in, or any response after a refresh) only if its `X-Updated-Access-Token-Version` is higher than the stored version. Two responses can arrive in either order, and the older one must not win.
2. **On `X-Authentication-Error: invalid_access_token`**, the token was replaced by a refresh. Usually the replacement is already stored, or is on its way in the response to another request:
   1. If storage now holds a higher version than the token this request sent, retry with it.
   2. If not, wait for a higher version to be stored, for up to the request timeout. Any request that could still bring one back finishes, or times out, within that window. Then retry with it.
   3. If none arrives, forget the token and sign in.
3. **On `sign_in_required`**, the session was revoked or expired, or the device signed out. Forget tokens up to the version that failed (a newer sign-in stored meanwhile survives) and sign in.
4. **On `accounts_unavailable` (503)**, retry later with the same token.

Rule 1 needs "keep the highest" to hold across everything sharing the token: an app and its extensions, or browser tabs. Rule 2 needs to see tokens stored by any of them. Neither the keychain nor `localStorage` has compare-and-set, and a lock across processes isn't safe on iOS, so both libraries do it without locks: **every version is a separate item**, the highest wins, and lower ones are deleted afterwards. Deleting only lower versions is safe whoever else is deleting. Changes are announced across processes with Darwin notifications (Swift) or `storage` events (browser), which wake waiters in rule 2.

The libraries implement all of this. A client only needs them for sign-in and its own requests.

**Swift** (`Clients/swift`, product `AuthenticationClient`; iOS 17+, macOS 14+):

```swift
let storage = KeychainAccessTokenStorage(
    service: "com.example.notes.access-token",
    accessGroup: "<TeamID>.com.example.notes"      // shared with the extensions
)
let session = AuthenticatedSession(storage: storage)

try await session.signIn(with: signInRequest)        // stores the token from the headers
let (data, response) = try await session.data(for: request)   // any request, any shape
try await session.signOut(with: signOutRequest)
```

It throws `AuthenticationClientError.signInRequired` or `.notSignedIn` when the person has to sign in. Use the same `service`, access group and keychain accessibility in the app and every extension. The default accessibility, `AfterFirstUnlockThisDeviceOnly`, lets extensions run while the device is locked. Requests with an `httpBodyStream` can't be resent, so they are never retried: use `httpBody`.

**TypeScript** (`Clients/typescript`, `@servicecore/authentication-client`):

```ts
const storage = new WebStorageTokenStorage("notes.access-token.");   // localStorage, shared by tabs
const fetch = createAuthenticatedFetch({ storage, newTokenTimeoutMs: 30_000 });

await signIn({ storage }, "/v1/auth/sign-in", { method: "POST", body });
const response = await fetch("/v1/notes", { method: "POST", body });
```

It throws `SignInRequiredError` or `NotSignedInError` when the person has to sign in. `localStorage` is readable by any script on the origin, so prefer keeping tokens server-side behind a cookie for browser apps where you can. `AccessTokenStorage` is an interface, so React Native secure storage or IndexedDB can stand in.

### Errors

Every authentication error carries `X-Authentication-Error`, so clients can act without decoding the body. Under ProtobufWireCore the body is an `ErrorDetail` in the `servicecore.auth` domain.

| `AuthenticationErrorCode` | `X-Authentication-Error` | Status | Client should |
|---|---|---|---|
| `missingAccessToken` | `missing_access_token` | 401 | sign in |
| `invalidAccessToken` | `invalid_access_token` | 401 | look for a newer token (rule 2), then sign in |
| `signInRequired` | `sign_in_required` | 401 | sign in |
| `invalidAuthorizationCode` | `invalid_authorization_code` | 400 | restart sign-in |
| `insufficientScope` | `insufficient_scope` | 403 | ask for `metadata["scope"]` |
| `accountsUnavailable` | `accounts_unavailable` | 503 | retry later with the same token |

401s also carry `WWW-Authenticate: Bearer error="invalid_token"` (RFC 6750), for generic OAuth clients.

### Session storage

`SessionStore` has three methods: `session(id:)`, `session(forToken:)` (the session whose *current* token has that digest), and an atomic compare-and-swap, `replace(_:expected:with:)`. `AuthenticationService` holds all the logic, so any database with a conditional write and a secondary lookup can back it. Tokens are stored only as SHA-256 digests, so reading the store never hands out a working access token. The refresh tokens it holds are useless without the client secret.

- `FoundationDBSessionStore` (`AuthenticationFoundationDB`) keeps `servicecore.auth.v1.Session` records in a Record Layer store of their own (path `auth-sessions`), indexed by token digest and by expiry. Run `removeExpired()` periodically (daily is plenty) to delete sessions nobody refreshed within `SessionPolicy.sessionLifetime` (60 days, matching accounts' refresh tokens).
- `InMemorySessionStore` is for tests and single-process development. A restart signs everyone out.

## Migrating

- `FoundationDBConnection.connect(defaultTenant:recordStorePath:config:)` → `connect(defaultTenant:config:)`. Pass the path to `RecordDatabase` instead.
- `connection.withRecordStore(schema) { … }` → `records.withStore { … }`.
- `ServiceFailure.notFound("…")` → `StandardError.notFound("…")`. All of `ServiceFailure`'s cases exist, plus `alreadyExists`, `cancelled` and `unavailable`.
- Automatio: its `ErrorCode` numbers `CONFLICT` as 5. Here (and in Ideatum) 5 is `ALREADY_EXISTS` and conflict is 6. Its clients need updating together with the service, or Automatio keeps its own enum as a `ServiceErrorCode` domain.
- Ideatum ServiceKit and Automatio still use `app.storage`, which Vapor 5 beta.4 removed. Move them to beta.4 first, as Aegis did.

## Tests

`swift test` runs everything on the server side. The clients have their own suites: `cd Clients/swift && swift test` (it uses the login keychain under a throwaway service name) and `cd Clients/typescript && npm install && npm test` (Node 22.18+). The `FoundationDBCore`, `RecordStore` and `AuthenticationCore` session-store suites need a local FoundationDB with tenants enabled. They use the `servicecore-tests` tenant and clear what they write.
