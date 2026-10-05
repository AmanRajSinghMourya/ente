import { afterEach, beforeEach, expect, test, vi } from "vitest";

const mocks = vi.hoisted(() => ({
    encode: vi.fn(),
    load: vi.fn(),
    workers: [] as {
        loaded: boolean;
        terminate: ReturnType<typeof vi.fn>;
        exec: ReturnType<typeof vi.fn>;
        unmount: ReturnType<typeof vi.fn>;
    }[],
}));
vi.mock("ente-base/log", () => ({
    default: { debug: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn() },
}));
vi.mock("../src/utils/video-encoding/web-codecs", () => ({
    encodeVideoWithWebCodecs: mocks.encode,
}));
vi.mock("@ffmpeg/ffmpeg", () => ({
    FFFSType: { WORKERFS: "WORKERFS" },
    FFmpeg: class {
        loaded = true;
        constructor() {
            mocks.workers.push(this);
        }
        load = mocks.load;
        terminate = vi.fn(() => {
            this.loaded = false;
        });
        on = vi.fn();
        off = vi.fn();
        createDir = vi.fn();
        deleteDir = vi.fn();
        mount = vi.fn();
        unmount = vi.fn();
        deleteFile = vi.fn();
        exec = vi.fn().mockResolvedValue(0);
        readFile = vi.fn().mockResolvedValue(new Uint8Array([7]));
    },
}));

beforeEach(() => {
    vi.resetModules();
    mocks.encode.mockReset();
    mocks.load.mockReset().mockResolvedValue(true);
    mocks.workers.length = 0;
    vi.stubGlobal("VideoEncoder", {});
    vi.stubGlobal("VideoDecoder", {});
});
afterEach(() => vi.unstubAllGlobals());

const exporter = async () => {
    const { transcodeVideoWeb } =
        await import("../src/utils/video-encoding/web");
    return (signal?: AbortSignal) =>
        transcodeVideoWeb(
            new Blob(["video"]),
            { start: 0, end: 10, muted: false },
            ["fallback"],
            signal,
        );
};

test("uses WebCodecs output without running the software encoder", async () => {
    const bytes = new Uint8Array([1, 2]);
    mocks.encode.mockResolvedValue(bytes);
    expect(await (await exporter())()).toBe(bytes);
    expect(mocks.workers[0]!.exec).not.toHaveBeenCalled();
    expect(mocks.workers[0]!.unmount).toHaveBeenCalled();
});

test("preloading and posting share the same in-flight engine load", async () => {
    let finish!: () => void;
    mocks.load.mockImplementationOnce(
        () =>
            new Promise<void>((resolve) => {
                finish = resolve;
            }),
    );
    const { preloadVideoEncoderWeb } =
        await import("../src/utils/video-encoding/web");
    const first = preloadVideoEncoderWeb();
    const second = preloadVideoEncoderWeb();
    const bytes = new Uint8Array([1, 2]);
    mocks.encode.mockResolvedValue(bytes);
    const posted = (await exporter())();
    expect(mocks.load).toHaveBeenCalledTimes(1);
    expect(mocks.encode).not.toHaveBeenCalled();
    finish();
    await Promise.all([first, second]);
    expect(await posted).toBe(bytes);
    expect(mocks.load).toHaveBeenCalledTimes(1);
    expect(mocks.workers).toHaveLength(1);
});

test("posting can retry after a failed preload", async () => {
    mocks.load.mockRejectedValueOnce(new Error("Offline"));
    const { preloadVideoEncoderWeb } =
        await import("../src/utils/video-encoding/web");
    await expect(preloadVideoEncoderWeb()).rejects.toThrow("Offline");
    mocks.encode.mockResolvedValue(new Uint8Array([2]));
    expect(await (await exporter())()).toEqual(new Uint8Array([2]));
    expect(mocks.workers[0]!.terminate).toHaveBeenCalled();
    expect(mocks.load).toHaveBeenCalledTimes(2);
});

test.each(["unsupported", "failed", "missing API"])(
    "keeps the software exporter available when WebCodecs is %s",
    async (mode) => {
        if (mode === "failed")
            mocks.encode.mockRejectedValue(new Error("Codec unavailable"));
        else mocks.encode.mockResolvedValue(undefined);
        if (mode === "missing API") vi.stubGlobal("VideoEncoder", undefined);
        expect(await (await exporter())()).toEqual(new Uint8Array([7]));
        expect(mocks.workers[0]!.exec).toHaveBeenCalledWith(["fallback"]);
        if (mode === "missing API") expect(mocks.encode).not.toHaveBeenCalled();
    },
);

test("cancellation stops the active export without starting the software fallback", async () => {
    mocks.encode.mockImplementation(
        (_ffmpeg, _path, _blob, _edit, signal: AbortSignal) =>
            new Promise((_, reject) =>
                signal.addEventListener(
                    "abort",
                    () => reject(new DOMException("Canceled", "AbortError")),
                    { once: true },
                ),
            ),
    );
    const controller = new AbortController();
    const pending = (await exporter())(controller.signal);
    const rejected = expect(pending).rejects.toMatchObject({
        name: "AbortError",
    });
    await vi.waitFor(() => expect(mocks.encode).toHaveBeenCalled());
    controller.abort();
    await rejected;
    expect(mocks.workers[0]!.terminate).toHaveBeenCalled();
    expect(mocks.workers[0]!.exec).not.toHaveBeenCalled();
});

test("a queued export can be cancelled without waiting for or stopping another export", async () => {
    let finish!: (bytes: Uint8Array) => void;
    mocks.encode.mockImplementation(
        () =>
            new Promise((resolve) => {
                finish = resolve;
            }),
    );
    const run = await exporter();
    const first = run();
    await vi.waitFor(() => expect(mocks.encode).toHaveBeenCalledTimes(1));
    const controller = new AbortController();
    const second = run(controller.signal);
    const rejected = expect(second).rejects.toMatchObject({
        name: "AbortError",
    });
    controller.abort();
    await rejected;
    expect(mocks.workers[0]!.terminate).not.toHaveBeenCalled();
    finish(new Uint8Array([1]));
    await first;
    expect(mocks.encode).toHaveBeenCalledTimes(1);
});

test("cancelling engine loading terminates it and allows the next export to load again", async () => {
    mocks.load.mockImplementationOnce(
        (_config, { signal }: { signal: AbortSignal }) =>
            new Promise((_, reject) =>
                signal.addEventListener(
                    "abort",
                    () => reject(new DOMException("Canceled", "AbortError")),
                    { once: true },
                ),
            ),
    );
    const run = await exporter();
    const controller = new AbortController();
    const pending = run(controller.signal);
    const rejected = expect(pending).rejects.toMatchObject({
        name: "AbortError",
    });
    await vi.waitFor(() => expect(mocks.load).toHaveBeenCalled());
    controller.abort();
    await rejected;
    mocks.encode.mockResolvedValue(new Uint8Array([2]));
    expect(await run()).toEqual(new Uint8Array([2]));
    expect(mocks.workers[0]!.terminate).toHaveBeenCalled();
    expect(mocks.workers).toHaveLength(2);
});
