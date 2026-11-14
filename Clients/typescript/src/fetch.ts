import type { AccessTokenStorage } from "./storage.ts";
import { waitForNewer } from "./storage.ts";
import { compareVersions, parseVersion, type AccessTokenVersion, type StoredAccessToken } from "./version.ts";

/** Response headers ServiceCore's `AuthenticationMiddleware` uses. */
export const AuthenticationHeaders = {
  updatedAccessToken: "X-Updated-Access-Token",
  updatedAccessTokenVersion: "X-Updated-Access-Token-Version",
  authenticationError: "X-Authentication-Error",
} as const;

/** No token is stored. */
export class NotSignedInError extends Error {
  constructor() {
    super("not signed in");
    this.name = "NotSignedInError";
  }
}

/** The session has ended, or no newer token turned up for an outdated one. */
export class SignInRequiredError extends Error {
  constructor() {
    super("sign in required");
    this.name = "SignInRequiredError";
  }
}

export interface AuthenticatedFetchOptions {
  storage: AccessTokenStorage;
  /** Defaults to the global `fetch`. */
  fetch?: typeof globalThis.fetch;
  /**
   * How long to wait for another request to bring back a refreshed token.
   * Use your request timeout: any request sent with the old token finishes, or
   * times out, within it. Defaults to 60 seconds.
   */
  newTokenTimeoutMs?: number;
}

/**
 * A `fetch` that sends the stored access token and follows ServiceCore's
 * refresh protocol:
 *
 * - Any response carrying `X-Updated-Access-Token` updates storage, unless a
 *   higher version is already stored.
 * - On `invalid_access_token` (the token was replaced by a refresh), it retries
 *   with a newer stored token. If there is none yet, another request (in this
 *   tab or another) may be about to bring it back, so it waits for one, for up
 *   to `newTokenTimeoutMs`, and only then gives up.
 * - On `sign_in_required` it forgets the token and throws
 *   {@link SignInRequiredError}.
 *
 * Other responses, errors included, are returned as they are.
 *
 * In a browser, cross-origin services must list the three headers in
 * `Access-Control-Expose-Headers`, or they are invisible here.
 */
export function createAuthenticatedFetch(options: AuthenticatedFetchOptions) {
  const { storage } = options;
  const send = options.fetch ?? globalThis.fetch.bind(globalThis);
  const timeoutMs = options.newTokenTimeoutMs ?? 60_000;

  const absorb = async (response: Response) => {
    const accessToken = response.headers.get(AuthenticationHeaders.updatedAccessToken);
    const version = parseVersion(response.headers.get(AuthenticationHeaders.updatedAccessTokenVersion));
    if (accessToken && version) await storage.offer({ accessToken, version });
  };

  const newer = async (version: AccessTokenVersion): Promise<StoredAccessToken | null> => {
    const current = await storage.current();
    if (current && compareVersions(current.version, version) > 0) return current;
    return waitForNewer(storage, version, timeoutMs);
  };

  return async function authenticatedFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
    let token = await storage.current();
    if (!token) throw new NotSignedInError();
    // Kept unsent, so every attempt can send a fresh copy of its body.
    const original = new Request(input, init);

    // Every retry needs a strictly newer token, so this ends; the cap is a backstop.
    for (let attempt = 0; attempt < 5; attempt++) {
      const request = original.clone();
      request.headers.set("Authorization", `Bearer ${token.accessToken}`);
      const response = await send(request);
      await absorb(response);

      switch (response.headers.get(AuthenticationHeaders.authenticationError)) {
        case "invalid_access_token": {
          const next = await newer(token.version);
          if (!next) {
            await storage.removeUpTo(token.version);
            throw new SignInRequiredError();
          }
          token = next;
          continue;
        }
        case "sign_in_required":
        case "missing_access_token":
          await storage.removeUpTo(token.version);
          throw new SignInRequiredError();
        default:
          return response;
      }
    }
    throw new SignInRequiredError();
  };
}

/** A sign-in response carried no token. */
export class MissingTokenError extends Error {
  constructor() {
    super(`the sign-in response carried no ${AuthenticationHeaders.updatedAccessToken} header`);
    this.name = "MissingTokenError";
  }
}

/**
 * Calls the service's sign-in endpoint (whatever its path and body) without a
 * token, and stores the token it returns in `X-Updated-Access-Token` and
 * `X-Updated-Access-Token-Version`. Resolves to the response, for whatever
 * else its body says.
 *
 * A failed sign-in (any non-2xx) is returned as it is; a successful one
 * without the headers throws {@link MissingTokenError}.
 */
export async function signIn(
  options: Pick<AuthenticatedFetchOptions, "storage" | "fetch">,
  input: RequestInfo | URL,
  init?: RequestInit,
): Promise<Response> {
  const send = options.fetch ?? globalThis.fetch.bind(globalThis);
  const response = await send(new Request(input, init));
  if (!response.ok) return response;
  const accessToken = response.headers.get(AuthenticationHeaders.updatedAccessToken);
  const version = parseVersion(response.headers.get(AuthenticationHeaders.updatedAccessTokenVersion));
  if (!accessToken || !version) throw new MissingTokenError();
  await options.storage.offer({ accessToken, version });
  return response;
}
