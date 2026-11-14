import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  MemoryTokenStorage, NotSignedInError, SignInRequiredError, WebStorageTokenStorage,
  compareVersions, createAuthenticatedFetch, parseVersion, signIn, waitForNewer,
  type AccessTokenVersion,
} from "../src/index.ts";

const v = (generation: number, signedInAt = 1_794_153_600_000n): AccessTokenVersion =>
  ({ signedInAt, generation: BigInt(generation) });
const invalid = { "X-Authentication-Error": "invalid_access_token" };
const updated = (token: string, version: AccessTokenVersion) => ({
  "X-Updated-Access-Token": token,
  "X-Updated-Access-Token-Version": `${version.signedInAt}.${version.generation}`,
});

/** A fake server: `handler` sees the bearer token and the body. */
function server(handler: (bearer: string | null, body: string) => { status: number; headers?: Record<string, string> } | Promise<{ status: number; headers?: Record<string, string> }>) {
  return async (request: Request) => {
    const bearer = request.headers.get("Authorization")?.replace(/^Bearer /, "") ?? null;
    const { status, headers } = await handler(bearer, await request.text());
    return new Response(null, { status, headers });
  };
}

/** A Web Storage in memory, as `localStorage` behaves. */
class MemoryWebStorage implements Storage {
  #items = new Map<string, string>();
  get length() { return this.#items.size; }
  key(index: number) { return [...this.#items.keys()][index] ?? null; }
  getItem(key: string) { return this.#items.get(key) ?? null; }
  setItem(key: string, value: string) { this.#items.set(key, value); }
  removeItem(key: string) { this.#items.delete(key); }
  clear() { this.#items.clear(); }
}

describe("versions", () => {
  it("parse and order", () => {
    assert.deepEqual(parseVersion("1794153600000.3"), v(3));
    assert.equal(parseVersion("1794153600000"), null);
    assert.equal(parseVersion("a.b"), null);
    assert.ok(compareVersions(v(0, 2n), v(9, 1n)) > 0);
    assert.ok(compareVersions(v(1), v(2)) < 0);
  });
});

describe("authenticated fetch", () => {
  it("stores updated tokens but never older ones", async () => {
    const storage = new MemoryTokenStorage({ accessToken: "a", version: v(0) });
    const fetch = createAuthenticatedFetch({
      storage,
      fetch: server((bearer) => bearer === "a"
        ? { status: 200, headers: updated("b", v(1)) }
        : { status: 200, headers: updated("a-again", v(0)) }),
    });
    await fetch("https://notes.test/v1/notes");
    assert.equal((await storage.current())?.accessToken, "b");
    await fetch("https://notes.test/v1/notes");
    assert.equal((await storage.current())?.accessToken, "b");
  });

  it("retries with a newer stored token, body intact", async () => {
    const storage = new MemoryTokenStorage({ accessToken: "a", version: v(0) });
    const fetch = createAuthenticatedFetch({
      storage,
      fetch: server(async (bearer, body) => {
        assert.equal(body, "payload");
        if (bearer === "b") return { status: 200 };
        await storage.offer({ accessToken: "b", version: v(1) });
        return { status: 401, headers: invalid };
      }),
    });
    const response = await fetch("https://notes.test/v1/notes", { method: "POST", body: "payload" });
    assert.equal(response.status, 200);
  });

  it("waits for a token still in flight", async () => {
    const storage = new MemoryTokenStorage({ accessToken: "a", version: v(0) });
    const fetch = createAuthenticatedFetch({
      storage, newTokenTimeoutMs: 5_000,
      fetch: server((bearer) => bearer === "b" ? { status: 200 } : { status: 401, headers: invalid }),
    });
    setTimeout(() => void storage.offer({ accessToken: "b", version: v(1) }), 150);
    const started = Date.now();
    assert.equal((await fetch("https://notes.test/")).status, 200);
    assert.ok(Date.now() - started >= 100);
  });

  it("gives up when no newer token arrives", async () => {
    const storage = new MemoryTokenStorage({ accessToken: "a", version: v(0) });
    const fetch = createAuthenticatedFetch({
      storage, newTokenTimeoutMs: 100, fetch: server(() => ({ status: 401, headers: invalid })),
    });
    await assert.rejects(fetch("https://notes.test/"), SignInRequiredError);
    assert.equal(await storage.current(), null);
  });

  it("an ended session keeps a newer sign-in", async () => {
    const storage = new MemoryTokenStorage({ accessToken: "a", version: v(0) });
    const fetch = createAuthenticatedFetch({
      storage,
      fetch: server(async () => {
        await storage.offer({ accessToken: "fresh", version: v(0, 1_794_153_700_000n) });
        return { status: 401, headers: { "X-Authentication-Error": "sign_in_required" } };
      }),
    });
    await assert.rejects(fetch("https://notes.test/"), SignInRequiredError);
    assert.equal((await storage.current())?.accessToken, "fresh");
  });

  it("returns other errors as they are", async () => {
    const storage = new MemoryTokenStorage({ accessToken: "a", version: v(0) });
    const fetch = createAuthenticatedFetch({ storage, fetch: server(() => ({ status: 503 })) });
    assert.equal((await fetch("https://notes.test/")).status, 503);
  });

  it("needs a token", async () => {
    const fetch = createAuthenticatedFetch({ storage: new MemoryTokenStorage(), fetch: server(() => ({ status: 200 })) });
    await assert.rejects(fetch("https://notes.test/"), NotSignedInError);
  });
});

describe("sign-in", () => {
  it("stores the token from the headers, whatever the body", async () => {
    const storage = new MemoryTokenStorage();
    const response = await signIn({
      storage,
      fetch: async (request) => {
        assert.equal((request as Request).headers.get("Authorization"), null);
        return new Response(JSON.stringify({ displayName: "Ada" }), { headers: updated("t0", v(0)) });
      },
    }, "https://notes.test/auth/sign-in", { method: "POST", body: "code=xyz" });
    assert.deepEqual(await response.json(), { displayName: "Ada" });
    assert.equal((await storage.current())?.accessToken, "t0");
  });

  it("returns failures without storing anything", async () => {
    const storage = new MemoryTokenStorage();
    const response = await signIn({ storage, fetch: server(() => ({ status: 400 })) }, "https://notes.test/auth/sign-in");
    assert.equal(response.status, 400);
    assert.equal(await storage.current(), null);
  });
});

describe("web storage", () => {
  it("keeps the highest version across tabs", async () => {
    const shared = new MemoryWebStorage();
    const tabA = new WebStorageTokenStorage("notes.token.", shared);
    const tabB = new WebStorageTokenStorage("notes.token.", shared);
    shared.setItem("unrelated", "x");

    assert.equal(await tabA.offer({ accessToken: "t1", version: v(1) }), true);
    assert.equal(await tabB.offer({ accessToken: "t0", version: v(0) }), false);
    assert.equal(await tabB.offer({ accessToken: "t2", version: v(2) }), true);
    assert.equal((await tabA.current())?.accessToken, "t2");
    assert.equal(shared.length, 2); // t2 and "unrelated": t1 was pruned.

    await tabA.removeUpTo(v(1));
    assert.equal((await tabB.current())?.accessToken, "t2");
    await tabA.removeUpTo(v(2));
    assert.equal(await tabB.current(), null);
    assert.equal(shared.getItem("unrelated"), "x");
  });

  it("hears other tabs through storage events", async () => {
    const shared = new MemoryWebStorage();
    const window = new EventTarget();
    const tab = new WebStorageTokenStorage("notes.token.", shared, window);
    await tab.offer({ accessToken: "t0", version: v(0) });

    setTimeout(() => {
      // Another tab writes; this one only learns of it from the event.
      shared.setItem("notes.token.1794153600000.1", "t1");
      const event = new Event("storage");
      Object.defineProperty(event, "key", { value: "notes.token.1794153600000.1" });
      window.dispatchEvent(event);
    }, 50);
    const newer = await waitForNewer(tab, v(0), 5_000);
    assert.equal(newer?.accessToken, "t1");
  });
});
