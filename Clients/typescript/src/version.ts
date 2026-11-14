/**
 * Orders a person's access tokens, across sign-ins as well as refreshes. Keep
 * the token with the highest version you have been given.
 *
 * Compared as (signedInAt, generation). On the wire it is
 * `<signedInAt>.<generation>`, e.g. `1794153600000.3`, as sent in
 * `X-Updated-Access-Token-Version` and by the service's sign-in endpoint.
 * Both parts are unsigned 64-bit, hence `bigint`.
 */
export interface AccessTokenVersion {
  /** When the session was signed in, in Unix milliseconds. */
  readonly signedInAt: bigint;
  /** How many times the session has been refreshed. */
  readonly generation: bigint;
}

/** An access token and its version. */
export interface StoredAccessToken {
  readonly accessToken: string;
  readonly version: AccessTokenVersion;
}

const pattern = /^(\d{1,20})\.(\d{1,20})$/;

/** Parses `<signedInAt>.<generation>`, or returns `null`. */
export function parseVersion(text: string | null | undefined): AccessTokenVersion | null {
  const match = text == null ? null : pattern.exec(text);
  return match ? { signedInAt: BigInt(match[1]), generation: BigInt(match[2]) } : null;
}

export function formatVersion(version: AccessTokenVersion): string {
  return `${version.signedInAt}.${version.generation}`;
}

/** Negative, zero or positive as `a` is lower than, equal to or higher than `b`. */
export function compareVersions(a: AccessTokenVersion, b: AccessTokenVersion): number {
  if (a.signedInAt !== b.signedInAt) return a.signedInAt < b.signedInAt ? -1 : 1;
  if (a.generation !== b.generation) return a.generation < b.generation ? -1 : 1;
  return 0;
}
