import { afterEach, beforeEach, expect, test, vi } from "vitest";
import {
    registerFeedPost,
    registerFeedVideo,
} from "../src/components/feed-video-playback";

let viewport: EventTarget & { innerHeight: number; scrollY: number };
let page: EventTarget & { hidden: boolean };
let frames: Map<number, FrameRequestCallback>;
let notifyVisibility: IntersectionObserverCallback;
let registrations: ReturnType<typeof registerFeedVideo>[];
let postCleanups: (() => void)[];
let playing: Set<string>;
let transitions: string[];

beforeEach(() => {
    vi.useFakeTimers();
    viewport = Object.assign(new EventTarget(), {
        innerHeight: 1000,
        scrollY: 0,
    });
    page = Object.assign(new EventTarget(), { hidden: false });
    frames = new Map();
    registrations = [];
    postCleanups = [];
    playing = new Set();
    transitions = [];
    let frame = 0;
    vi.stubGlobal("window", viewport);
    vi.stubGlobal("document", page);
    vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
        frames.set(++frame, callback);
        return frame;
    });
    vi.stubGlobal("cancelAnimationFrame", (id: number) => frames.delete(id));
    vi.stubGlobal(
        "IntersectionObserver",
        class {
            constructor(callback: IntersectionObserverCallback) {
                notifyVisibility = callback;
            }
            observe = vi.fn();
            unobserve = vi.fn();
            disconnect = vi.fn();
        },
    );
});

afterEach(() => {
    registrations.forEach((registration) => registration.unregister());
    postCleanups.forEach((cleanup) => cleanup());
    vi.unstubAllGlobals();
    vi.useRealTimers();
});

const flush = () => {
    const callbacks = [...frames.values()];
    frames.clear();
    callbacks.forEach((callback) => callback(0));
};

const visibility = (element: HTMLElement, ratio: number) => {
    notifyVisibility(
        [
            {
                target: element,
                boundingClientRect: element.getBoundingClientRect(),
                intersectionRect: element.getBoundingClientRect(),
                intersectionRatio: ratio,
                isIntersecting: ratio > 0,
                rootBounds: null,
                time: 0,
            },
        ],
        {} as IntersectionObserver,
    );
};

const addPost = (top: number, height = 250) => {
    const children = new Set<HTMLElement>();
    const element = {
        getBoundingClientRect: () => ({
            top: top - viewport.scrollY,
            bottom: top + height - viewport.scrollY,
            height,
        }),
        contains: (element: HTMLElement) => children.has(element),
    } as unknown as HTMLElement;
    const cleanup = registerFeedPost(element);
    postCleanups.push(cleanup);
    visibility(element, 1);
    return { element, children, cleanup };
};

const addVideo = (
    name: string,
    top: number,
    active = true,
    height = 250,
    post = addPost(top, height),
) => {
    const element = {
        getBoundingClientRect: () => post.element.getBoundingClientRect(),
    } as HTMLElement;
    post.children.add(element);
    const stop = () => {
        playing.delete(name);
        transitions.push(`stop ${name}`);
    };
    const player = {
        play: vi.fn(() => {
            expect(playing.size).toBe(0);
            playing.add(name);
            transitions.push(`play ${name}`);
        }),
        pause: vi.fn(stop),
        deactivate: vi.fn(stop),
    };
    const control = registerFeedVideo(element, player);
    registrations.push(control);
    control.setActive(active);
    return { element, player, control, post };
};

const scrollTo = (y: number, settle = true) => {
    viewport.scrollY = y;
    viewport.dispatchEvent(new Event("scroll"));
    flush();
    if (settle) vi.advanceTimersByTime(150);
};

test("autoplay waits for scrolling to settle and skips posts passed along the way", () => {
    addVideo("upper", 100);
    addVideo("middle", 500);
    addVideo("lower", 1000);
    flush();
    scrollTo(400, false);
    expect(playing.size).toBe(0);
    vi.advanceTimersByTime(100);
    scrollTo(900, false);
    vi.advanceTimersByTime(100);
    expect(playing.size).toBe(0);
    vi.advanceTimersByTime(50);
    expect(transitions).toEqual(["play upper", "stop upper", "play lower"]);
});

test("observer updates during scrolling do not start playback", () => {
    const video = addVideo("video", 900);
    flush();
    scrollTo(700, false);
    visibility(video.post.element, 1);
    flush();
    expect(playing.size).toBe(0);
    vi.advanceTimersByTime(150);
    expect([...playing]).toEqual(["video"]);
});

test("manual play takes effect immediately even before scrolling settles", () => {
    const upper = addVideo("upper", -200);
    addVideo("focused", 100);
    flush();
    scrollTo(10, false);
    upper.control.play();
    expect([...playing]).toEqual(["upper"]);
    vi.advanceTimersByTime(150);
    expect(transitions).toEqual(["play focused", "stop focused", "play upper"]);
});

test("a short landscape video plays before a lower video crossing the midpoint", () => {
    addVideo("landscape", 100, true, 180);
    addVideo("lower", 320, true, 500);
    flush();
    expect([...playing]).toEqual(["landscape"]);
    expect(transitions).toEqual(["play landscape"]);
});

test("selection follows post position rather than registration order", () => {
    addVideo("lower", 400);
    addVideo("upper", 100);
    flush();
    expect([...playing]).toEqual(["upper"]);
});

test("playback transfers only after less than half of the first post remains visible", () => {
    addVideo("upper", 100, true, 200);
    addVideo("lower", 400);
    flush();
    scrollTo(200);
    expect([...playing]).toEqual(["upper"]);
    scrollTo(201);
    expect([...playing]).toEqual(["lower"]);
    expect(transitions).toEqual(["play upper", "stop upper", "play lower"]);
});

test("scrolling back up restores the earlier eligible post", () => {
    addVideo("upper", 100);
    addVideo("lower", 400);
    flush();
    scrollTo(300);
    expect([...playing]).toEqual(["lower"]);
    scrollTo(0);
    expect([...playing]).toEqual(["upper"]);
});

test("a video entering the bottom of the viewport does not steal playback", () => {
    addVideo("upper", 100);
    flush();
    addVideo("new", 700);
    flush();
    expect(transitions).toEqual(["play upper"]);
});

test("a mostly visible photo blocks autoplay in the next post", () => {
    addPost(100);
    addVideo("lower", 400);
    flush();
    expect(playing.size).toBe(0);
});

test("an unloaded post blocks autoplay in the next post until its video is ready", () => {
    const post = addPost(100);
    addVideo("lower", 400);
    flush();
    expect(playing.size).toBe(0);
    addVideo("upper", 100, true, 250, post);
    flush();
    expect([...playing]).toEqual(["upper"]);
});

test("swiping the focused post to a photo does not start another post's video", () => {
    addVideo("upper", -200);
    const focused = addVideo("focused", 100);
    addVideo("lower", 400);
    flush();
    focused.control.setActive(false);
    flush();
    expect(playing.size).toBe(0);
    expect(transitions).toEqual(["play focused", "stop focused"]);
    focused.control.setActive(true);
    flush();
    expect([...playing]).toEqual(["focused"]);
});

test("swiping the focused carousel between videos pauses the old slide first", () => {
    const first = addVideo("first", 100);
    const second = addVideo("second", 100, false, 250, first.post);
    flush();
    first.control.setActive(false);
    second.control.setActive(true);
    flush();
    expect(transitions).toEqual(["play first", "stop first", "play second"]);
});

test("swiping another carousel to a video does not steal playback", () => {
    addVideo("upper", 100);
    const lower = addVideo("lower", 400, false);
    flush();
    lower.control.setActive(true);
    flush();
    expect(transitions).toEqual(["play upper"]);
});

test("tapping a partially visible video overrides autoplay synchronously", () => {
    const upper = addVideo("upper", -200);
    addVideo("focused", 100);
    flush();
    upper.control.play();
    expect(transitions).toEqual(["play focused", "stop focused", "play upper"]);
    scrollTo(10);
    viewport.dispatchEvent(new Event("resize"));
    visibility(upper.post.element, 0.16);
    flush();
    expect([...playing]).toEqual(["upper"]);
});

test("manual playback returns to autoplay when the chosen video leaves the screen", () => {
    const upper = addVideo("upper", -200);
    addVideo("focused", 100);
    flush();
    upper.control.play();
    scrollTo(51);
    expect([...playing]).toEqual(["focused"]);
    expect(transitions).toEqual([
        "play focused",
        "stop focused",
        "play upper",
        "stop upper",
        "play focused",
    ]);
});

test("manual playback releases an inactive carousel slide", () => {
    addVideo("upper", 100);
    const lower = addVideo("lower", 400);
    flush();
    lower.control.play();
    lower.control.setActive(false);
    flush();
    expect([...playing]).toEqual(["upper"]);
});

test("manual pause keeps other videos paused until an explicit resume or leaving the screen", () => {
    const upper = addVideo("upper", -200);
    addVideo("focused", 100);
    flush();
    upper.control.play();
    upper.control.pause();
    scrollTo(10);
    expect(playing.size).toBe(0);
    upper.control.play();
    expect([...playing]).toEqual(["upper"]);
    upper.control.pause();
    scrollTo(51);
    expect([...playing]).toEqual(["focused"]);
});

test("inactive or offscreen videos cannot be started manually", () => {
    const inactive = addVideo("inactive", 100, false);
    const offscreen = addVideo("offscreen", -300);
    flush();
    inactive.control.play();
    offscreen.control.play();
    expect(playing.size).toBe(0);
});

test("a tall post is eligible when at least half the viewport is covered", () => {
    const video = addVideo("tall", -500, true, 2500);
    visibility(video.post.element, 0.4);
    flush();
    expect([...playing]).toEqual(["tall"]);
});

test("playback stops when no post is sufficiently visible", () => {
    addVideo("upper", -200);
    addVideo("lower", 900);
    flush();
    expect(playing.size).toBe(0);
});

test("nonintersecting posts do not autoplay", () => {
    const video = addVideo("clipped", 100);
    visibility(video.post.element, 0);
    flush();
    expect(playing.size).toBe(0);
});

test("automatic playback respects pause until the post leaves and returns", () => {
    const video = addVideo("upper", 100);
    addVideo("lower", 400);
    flush();
    video.control.pause();
    scrollTo(10);
    expect(playing.size).toBe(0);
    scrollTo(400);
    expect([...playing]).toEqual(["lower"]);
    scrollTo(0);
    expect([...playing]).toEqual(["upper"]);
});

test("resizing the viewport updates post eligibility", () => {
    addVideo("lower", 450, true, 200);
    flush();
    expect([...playing]).toEqual(["lower"]);
    viewport.innerHeight = 500;
    viewport.dispatchEvent(new Event("resize"));
    flush();
    expect(playing.size).toBe(0);
});

test("hiding the tab stops playback and preserves manual choice on return", () => {
    addVideo("upper", 100);
    const lower = addVideo("lower", 400);
    flush();
    lower.control.play();
    page.hidden = true;
    page.dispatchEvent(new Event("visibilitychange"));
    expect(playing.size).toBe(0);
    page.hidden = false;
    page.dispatchEvent(new Event("visibilitychange"));
    expect([...playing]).toEqual(["lower"]);
});

test("manual pause survives hiding and restoring the tab", () => {
    const upper = addVideo("upper", -200);
    addVideo("focused", 100);
    flush();
    upper.control.play();
    upper.control.pause();
    page.hidden = true;
    page.dispatchEvent(new Event("visibilitychange"));
    page.hidden = false;
    page.dispatchEvent(new Event("visibilitychange"));
    expect(playing.size).toBe(0);
});

test("unmounting releases playback and ignores queued observer notifications", () => {
    const video = addVideo("upper", 100);
    flush();
    video.control.unregister();
    video.post.cleanup();
    registrations = [];
    postCleanups = [];
    visibility(video.post.element, 1);
    viewport.dispatchEvent(new Event("scroll"));
    flush();
    expect(playing.size).toBe(0);
    expect(video.player.play).toHaveBeenCalledTimes(1);
});
