import { FFFSType, FFmpeg } from "@ffmpeg/ffmpeg";
import { joinPath } from "ente-base/file-name";
import { newID } from "ente-base/id";
import log from "ente-base/log";
import type { FFmpegCommand } from "ente-base/types/ipc";
import { ensureArrayBufferBacked } from "ente-utils/bytes";
import { PromiseQueue } from "ente-utils/promise";
import { z } from "zod";
import { inputPathPlaceholder, outputPathPlaceholder } from "./constants";
import type { VideoTranscodeEdit } from "./web-codecs";

let _ffmpeg: Promise<FFmpeg> | undefined;

const _ffmpegTaskQueue = new PromiseQueue<unknown>();

const ffmpegLazy = (signal?: AbortSignal): Promise<FFmpeg> =>
    (_ffmpeg ??= createFFmpeg(signal));

const createFFmpeg = async (signal?: AbortSignal) => {
    const ffmpeg = new FFmpeg();
    try {
        await ffmpeg.load(
            {
                coreURL:
                    "https://assets.ente.com/ffmpeg-core-0.12.10/ffmpeg-core.js",
                wasmURL:
                    "https://assets.ente.com/ffmpeg-core-0.12.10/ffmpeg-core.wasm",
            },
            { signal },
        );
        return ffmpeg;
    } catch (error) {
        ffmpeg.terminate();
        _ffmpeg = undefined;
        throw error;
    }
};

export const preloadVideoEncoderWeb = async () => {
    await ffmpegLazy();
};

export const determineVideoDurationWeb = async (
    blob: Blob,
    signal?: AbortSignal,
): Promise<number> =>
    runFFmpegTask((ffmpeg) => ffprobeExecVideoDuration(ffmpeg, blob), signal);

export const transcodeVideoWeb = (
    blob: Blob,
    edit: VideoTranscodeEdit,
    fallbackCommand: FFmpegCommand,
    signal?: AbortSignal,
) =>
    runFFmpegTask(async (ffmpeg) => {
        if (
            typeof VideoDecoder !== "undefined" &&
            typeof VideoEncoder !== "undefined"
        ) {
            try {
                const { encodeVideoWithWebCodecs } =
                    await import("./web-codecs");
                const result = await withInputMount(ffmpeg, blob, (inputPath) =>
                    encodeVideoWithWebCodecs(
                        ffmpeg,
                        inputPath,
                        blob,
                        edit,
                        signal,
                    ),
                );
                if (result) {
                    log.debug(() => "Encoded video with WebCodecs");
                    return result;
                }
            } catch (error) {
                signal?.throwIfAborted();
                log.warn("WebCodecs export failed, using FFmpeg", error);
            }
        }
        signal?.throwIfAborted();
        return ffmpegExec(ffmpeg, fallbackCommand, "mp4", blob);
    }, signal);

const runFFmpegTask = <T>(
    task: (ffmpeg: FFmpeg) => Promise<T>,
    signal?: AbortSignal,
): Promise<T> => {
    const pending = _ffmpegTaskQueue.add(async () => {
        signal?.throwIfAborted();
        const ffmpeg = await ffmpegLazy(signal);
        signal?.throwIfAborted();
        const abort = () => {
            ffmpeg.terminate();
            _ffmpeg = undefined;
        };
        signal?.addEventListener("abort", abort, { once: true });
        try {
            return await task(ffmpeg);
        } catch (error) {
            signal?.throwIfAborted();
            throw error;
        } finally {
            signal?.removeEventListener("abort", abort);
        }
    }) as Promise<T>;
    if (!signal) return pending;
    return new Promise<T>((resolve, reject) => {
        const abort = () => reject(new DOMException("Canceled", "AbortError"));
        signal.addEventListener("abort", abort, { once: true });
        void pending
            .then(resolve, reject)
            .finally(() => signal.removeEventListener("abort", abort));
        if (signal.aborted) abort();
    });
};

const ffmpegExec = async (
    ffmpeg: FFmpeg,
    command: FFmpegCommand,
    outputFileExtension: string,
    blob: Blob,
): Promise<Uint8Array<ArrayBuffer>> => {
    const outputSuffix = outputFileExtension ? "." + outputFileExtension : "";
    const outputPath = newID("out_") + outputSuffix;

    let status: number | undefined;

    return withInputMount(ffmpeg, blob, async (inputPath) => {
        try {
            const startTime = Date.now();

            let resolvedCommand: string[];
            if (Array.isArray(command)) {
                resolvedCommand = command;
            } else {
                const isHDR = await isHDRVideo(ffmpeg, inputPath);
                resolvedCommand = isHDR ? command.hdr : command.default;
            }

            const cmd = substitutePlaceholders(
                resolvedCommand,
                inputPath,
                outputPath,
            );

            status = await ffmpeg.exec(cmd);
            if (status !== 0) {
                log.info(
                    `[wasm] ffmpeg command failed with exit code ${status}: ${cmd.join(" ")}`,
                );
                throw new Error(
                    `ffmpeg command failed with exit code ${status}`,
                );
            }

            const result = await ffmpeg.readFile(outputPath);
            if (typeof result == "string")
                throw new Error("Expected binary data");

            const ms = Date.now() - startTime;
            log.debug(() => `[wasm] ffmpeg ${cmd.join(" ")} (${ms} ms)`);
            return ensureArrayBufferBacked(result);
        } finally {
            try {
                if (ffmpeg.loaded) await ffmpeg.deleteFile(outputPath);
            } catch (e) {
                if (status === 0) {
                    log.error(`Failed to remove output ${outputPath}`, e);
                }
            }
        }
    });
};

const withInputMount = async <T>(
    ffmpeg: FFmpeg,
    blob: Blob,
    f: (inputPath: string) => Promise<T>,
): Promise<T> => {
    const mountDir = "/mount";
    const inputFileName = newID("in_");
    const inputPath = joinPath(mountDir, inputFileName);

    const inputFile = new File([blob], inputFileName);

    try {
        await ffmpeg.createDir(mountDir);
        await ffmpeg.mount(FFFSType.WORKERFS, { files: [inputFile] }, mountDir);

        return await f(inputPath);
    } finally {
        try {
            if (ffmpeg.loaded) await ffmpeg.unmount(mountDir);
        } catch (e) {
            log.error(`Failed to remove mount ${mountDir}`, e);
        }
        try {
            if (ffmpeg.loaded) await ffmpeg.deleteDir(mountDir);
        } catch (e) {
            log.error(`Failed to delete mount directory ${mountDir}`, e);
        }
    }
};

const substitutePlaceholders = (
    command: string[],
    inputFilePath: string,
    outputFilePath: string,
) =>
    command.map((segment) => {
        if (segment == inputPathPlaceholder) {
            return inputFilePath;
        } else if (segment == outputPathPlaceholder) {
            return outputFilePath;
        } else {
            return segment;
        }
    });

const FFProbeOutputIsHDR = z.object({
    streams: z.array(z.object({ color_transfer: z.string().optional() })),
});

const isHDRVideo = async (ffmpeg: FFmpeg, inputFilePath: string) => {
    let jsonString: string | undefined;
    try {
        jsonString = await ffprobeOutput(
            ffmpeg,
            [
                ["-i", inputFilePath],
                "-show_streams",
                ["-select_streams", "v:0"],
                ["-of", "json"],
                ["-o", "output.json"],
            ].flat(),
            "output.json",
        );

        const output = FFProbeOutputIsHDR.parse(JSON.parse(jsonString));
        switch (output.streams[0]?.color_transfer) {
            case "smpte2084":
            case "arib-std-b67":
                return true;
            default:
                return false;
        }
    } catch (e) {
        log.warn("Could not detect HDR status", e);
        if (jsonString) log.debug(() => ["ffprobe-output", jsonString]);
        return false;
    }
};

const ffprobeOutput = async (
    ffmpeg: FFmpeg,
    cmd: string[],
    outputPath: string,
) => {
    let status: number | undefined;

    try {
        status = await ffmpeg.ffprobe(cmd);
        if (status !== 0 && status != -1) {
            log.info(
                `[wasm] ffprobe command failed with exit code ${status}: ${cmd.join(" ")}`,
            );
            throw new Error(`ffprobe command failed with exit code ${status}`);
        }

        const result = await ffmpeg.readFile(outputPath, "utf8");
        if (typeof result != "string") throw new Error("Expected text data");

        return result;
    } finally {
        try {
            if (ffmpeg.loaded) await ffmpeg.deleteFile(outputPath);
        } catch (e) {
            if (status === 0 || status == -1) {
                log.error(`Failed to remove output ${outputPath}`, e);
            }
        }
    }
};

const FFProbeOutputDuration = z.object({
    format: z.object({ duration: z.string() }),
});

const ffprobeExecVideoDuration = async (ffmpeg: FFmpeg, blob: Blob) =>
    withInputMount(ffmpeg, blob, async (inputPath) => {
        const jsonString = await ffprobeOutput(
            ffmpeg,
            [
                ["-i", inputPath],
                ["-v", "error"],
                ["-show_entries", "format=duration"],
                ["-of", "json"],
                ["-o", "output.json"],
            ].flat(),
            "output.json",
        );

        const durationString = FFProbeOutputDuration.parse(
            JSON.parse(jsonString),
        ).format.duration;

        const duration = parseFloat(durationString);
        if (isNaN(duration)) {
            const msg = "Could not parse video duration";
            log.warn(msg, durationString);
            throw new Error(msg);
        }
        return duration;
    });
