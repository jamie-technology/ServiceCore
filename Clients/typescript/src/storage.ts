import { compareVersions, formatVersion, parseVersion, type AccessTokenVersion, type StoredAccessToken } from "./version.ts";

/**
 * Where the access token lives, shared by everything that uses it (tabs,
 * workers, or an app's processes).
 *
 * Implementations must make "keep the highest version" hold however writes
 * interleave, without relying on a compare-and-set the underlying storage may
 * not have. {@link WebStorageTokenStorage} does it by never overwriting:
 * every version is its own key, and the highest wins.
 */
export interface AccessTokenStorage {
  /** The highest-version token stored, or `null` when signed out. */
  current(): Promise<StoredAccessToken | null>;
  /**
   * Stores `token` unless a higher version is already stored, and tells every
   * subscriber. Resolves to whether `token` is now current.
   */
  offer(token: StoredAccessToken): Promise<boolean>;
  /**
   * Removes tokens up to and including `version`: after the service said the
   * session has ended. A token from a newer sign-in survives.
   */
  removeUpTo(version: AccessTokenVersion): Promise<void>;
  /** Removes every token: signing out. */
  removeAll(): Promise<void>;
  /**
   * Calls `listener` whenever anything changes the storage; changes may be
   * coalesced, so read `current()` after each. Returns an unsubscribe function.
   */
  subscribe(listener: () => void): () => void;
}

/**
 * Waits up to `timeoutMs` for a token with a version higher than `version`.
 * Resolves to it, or `null`.
 */
export async function waitForNewer(
  storage: AccessTokenStorage,
  version: AccessTokenVersion,
  timeoutMs: number,
): Promise<StoredAccessToken | null> {
  const newer = async () => {
    const current = await storage.current();
    return current && compareVersions(current.version, version) > 0 ? current : null;
  };

  return new Promise<StoredAccessToken | null>((resolve, reject) => {
    let settled = false;
    const finish = (value: StoredAccessToken | null) => {
      if (settled) return;
      settled = true;
      unsubscribe();
      clearTimeout(timer);
      resolve(value);
    };
    const check = () => {
      newer().then((token) => token && finish(token), (error) => {
        if (!settled) {
          settled = true;
          unsubscribe();
          clearTimeout(timer);
          reject(error);
        }
      });
    };
    // Subscribe before looking, so a change between the two is not missed.
    const unsubscribe = storage.subscribe(check);
    // Notifications can be coalesced or lost: look once more at the deadline.
    const timer = setTimeout(() => newer().then(finish, () => finish(null)), timeoutMs);
    check();
  });
}

/** An {@link AccessTokenStorage} in memory: for tests and single-page sessions. */
export class MemoryTokenStorage implements AccessTokenStorage {
  #token: StoredAccessToken | null;
  #listeners = new Set<() => void>();

  constructor(token: StoredAccessToken | null = null) {
    this.#token = token;
  }

  async current() {
    return this.#token;
  }

  async offer(token: StoredAccessToken) {
    const current = this.#token;
    if (current && compareVersions(current.version, token.version) >= 0) {
      return compareVersions(current.version, token.version) === 0 && current.accessToken === token.accessToken;
    }
    this.#token = token;
    this.#notify();
    return true;
  }

  async removeUpTo(version: AccessTokenVersion) {
    if (this.#token && compareVersions(this.#token.version, version) <= 0) this.#token = null;
    this.#notify();
  }

  async removeAll() {
    this.#token = null;
    this.#notify();
  }

  subscribe(listener: () => void) {
    this.#listeners.add(listener);
    return () => void this.#listeners.delete(listener);
  }

  #notify() {
    for (const listener of [...this.#listeners]) listener();
  }
}

/**
 * The token in `localStorage` (or any Web Storage), shared by an origin's tabs.
 *
 * Every version is its own key (`<prefix><signedInAt>.<generation>`), so tabs
 * writing at once never overwrite each other's tokens: the highest version
 * wins everywhere, and lower ones are deleted afterwards. Other tabs hear about
 * changes through `storage` events.
 *
 * Anything in Web Storage is readable by script on the origin, so an XSS bug
 * exposes the token. Prefer keeping the token server-side behind a cookie for
 * browser apps where you can; use this when the client must hold it.
 */
export class WebStorageTokenStorage implements AccessTokenStorage {
  readonly #storage: Storage;
  readonly #prefix: string;
  readonly #listeners = new Set<() => void>();
  readonly #target: EventTarget | null;

  /**
   * @param prefix Key prefix, unique to this service, e.g. `"notes.access-token."`.
   * @param storage Defaults to `localStorage`.
   * @param target Where `storage` events arrive; defaults to `globalThis` when
   *   it dispatches them (a browser window).
   */
  constructor(prefix: string, storage: Storage = globalThis.localStorage, target: EventTarget | null = null) {
    this.#prefix = prefix;
    this.#storage = storage;
    this.#target = target ?? (typeof globalThis.addEventListener === "function" ? globalThis : null);
  }

  async current() {
    const versions = this.#versions();
    const highest = versions.at(-1);
    if (!highest) return null;
    const accessToken = this.#storage.getItem(this.#key(highest));
    if (accessToken == null) return null;
    this.#prune(highest, versions);
    return { accessToken, version: highest };
  }

  async offer(token: StoredAccessToken) {
    const versions = this.#versions();
    const highest = versions.at(-1);
    if (highest && compareVersions(highest, token.version) >= 0) {
      return compareVersions(highest, token.version) === 0;
    }
    this.#storage.setItem(this.#key(token.version), token.accessToken);
    this.#prune(token.version, versions);
    this.#notify();
    return true;
  }

  async removeUpTo(version: AccessTokenVersion) {
    for (const stored of this.#versions()) {
      if (compareVersions(stored, version) <= 0) this.#storage.removeItem(this.#key(stored));
    }
    this.#notify();
  }

  async removeAll() {
    for (const stored of this.#versions()) this.#storage.removeItem(this.#key(stored));
    this.#notify();
  }

  subscribe(listener: () => void) {
    this.#listeners.add(listener);
    const onStorage = (event: Event) => {
      const key = (event as StorageEvent).key;
      if (key == null || key.startsWith(this.#prefix)) listener();
    };
    this.#target?.addEventListener("storage", onStorage);
    return () => {
      this.#listeners.delete(listener);
      this.#target?.removeEventListener("storage", onStorage);
    };
  }

  #key(version: AccessTokenVersion) {
    return this.#prefix + formatVersion(version);
  }

  /** Every stored version, lowest first. */
  #versions(): AccessTokenVersion[] {
    const versions: AccessTokenVersion[] = [];
    for (let index = 0; index < this.#storage.length; index++) {
      const key = this.#storage.key(index);
      if (key?.startsWith(this.#prefix)) {
        const version = parseVersion(key.slice(this.#prefix.length));
        if (version) versions.push(version);
      }
    }
    return versions.sort(compareVersions);
  }

  /** Deleting only lower versions is safe whoever else is pruning. */
  #prune(below: AccessTokenVersion, versions: AccessTokenVersion[]) {
    for (const stored of versions) {
      if (compareVersions(stored, below) < 0) this.#storage.removeItem(this.#key(stored));
    }
  }

  #notify() {
    // `storage` events only reach other tabs; tell this one directly.
    for (const listener of [...this.#listeners]) listener();
  }
}
