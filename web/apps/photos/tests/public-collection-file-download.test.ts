import { fetchPublicCollectionFile } from "ente-base/file-download";
import { afterEach, describe, expect, test, vi } from "vitest";

vi.mock("ente-base/origins", () => ({
    apiURL: (path: string) => Promise.resolve(`https://api.test${path}`),
    customAPIOrigin: () => Promise.resolve(undefined),
}));

const credentials = { accessToken: "access", anonUserToken: "guest-token" };

const headersOf = (init?: RequestInit) => new Headers(init?.headers);

describe("fetchPublicCollectionFile", () => {
    afterEach(() => {
        vi.unstubAllGlobals();
        vi.useRealTimers();
    });

    test("sends the guest token to V3 but not to the object URL", async () => {
        const fetchMock = vi
            .fn()
            .mockResolvedValueOnce(
                new Response(
                    JSON.stringify({ url: "https://bucket.test/object" }),
                ),
            )
            .mockResolvedValueOnce(new Response("bytes"));
        vi.stubGlobal("fetch", fetchMock);

        await fetchPublicCollectionFile(1, "thumbnail", credentials);

        const [v3Call, objectCall] = fetchMock.mock.calls as [
            [string, RequestInit],
            [string, RequestInit?],
        ];
        expect(v3Call[0]).toBe(
            "https://api.test/public-collection/files/thumbnail/v3/1",
        );
        expect(headersOf(v3Call[1]).get("X-Anon-User-Token")).toBe(
            "guest-token",
        );
        expect(objectCall).toEqual(["https://bucket.test/object"]);
    });

    test("keeps the guest token off the legacy redirect fallback", async () => {
        vi.useFakeTimers();
        vi.setSystemTime(Date.now() + 2 * 60 * 60 * 1000);
        const fetchMock = vi
            .fn()
            .mockResolvedValueOnce(new Response(null, { status: 404 }))
            .mockResolvedValueOnce(new Response("bytes"));
        vi.stubGlobal("fetch", fetchMock);

        await fetchPublicCollectionFile(2, "file", credentials);

        const [, legacyCall] = fetchMock.mock.calls as [
            [string, RequestInit],
            [string, RequestInit],
        ];
        expect(legacyCall[0]).toBe(
            "https://api.test/public-collection/files/download/2",
        );
        const headers = headersOf(legacyCall[1]);
        expect(headers.get("X-Auth-Access-Token")).toBe("access");
        expect(headers.has("X-Anon-User-Token")).toBe(false);
    });
});
