import { beforeEach, expect, test, vi } from "vitest";
import {
    createCurrentMediaPost,
    loadCurrentCreatedPost,
    type SpacePostUploadSession,
} from "../src/services/space";

const mocks = vi.hoisted(() => ({
    ctx: {
        generatePostKey: vi.fn(),
        uploadPostPhotoAsset: vi.fn(),
        createMediaPost: vi.fn(),
        getPost: vi.fn(),
        downloadPostAsset: vi.fn(),
    },
    release: vi.fn(),
    cacheMedia: vi.fn(),
    cachePost: vi.fn(),
}));

vi.mock("services/profile", () => ({
    ensureCurrentSpaceContext: () => Promise.resolve(mocks.ctx),
    releaseCurrentSpaceContext: mocks.release,
}));
vi.mock("services/feed-cache", () => ({
    prependCachedSpaceFeedPost: mocks.cachePost,
}));
vi.mock("services/media-cache", () => ({
    rememberCachedSpaceMediaBlobURL: mocks.cacheMedia,
    spacePostMediaCacheKey: (spaceId: string, key: string) =>
        `${spaceId}:${key}`,
    clearSpaceMediaURLCache: vi.fn(),
}));
vi.mock("ente-base/log", () => ({ default: { warn: vi.fn() } }));

const file = new File(["photo"], "photo.webp", { type: "image/webp" });
const images = [{ file, width: 1200, height: 800, thumbHash: "hash" }];
const asset = {
    objectKey: "photo-1",
    postId: 501,
    spaceId: "self",
    encryptedPostKey: "encrypted-key",
    keyVersion: 1,
};

beforeEach(() => {
    vi.resetAllMocks();
    mocks.ctx.generatePostKey.mockReturnValue(new Uint8Array(32));
    mocks.ctx.uploadPostPhotoAsset.mockResolvedValue({
        objectKey: "photo-1",
        size: 100,
        metadataCipher: "metadata",
    });
    mocks.ctx.createMediaPost.mockResolvedValue(501n);
    mocks.ctx.getPost.mockResolvedValue({
        postId: 501,
        spaceId: "self",
        caption: "Caption",
        createdAt: "2026-09-30T00:00:00Z",
        viewerLiked: false,
        author: {
            spaceId: "self",
            spaceSlug: "self",
            profile: { fullName: "Self" },
            avatar: { objectID: "avatar", keyVersion: 1 },
        },
        photos: [{ asset, width: 1200, height: 800, mediaType: "image/webp" }],
    });
    mocks.cacheMedia.mockResolvedValue("blob:preview");
});

test("confirms creation without waiting for a post readback", async () => {
    mocks.ctx.getPost.mockRejectedValue(new Error("Offline"));
    const session: SpacePostUploadSession = { uploads: [] };
    await expect(
        createCurrentMediaPost({
            images,
            caption: "Caption",
            spaceId: "self",
            session,
        }),
    ).resolves.toBe(501);
    expect(session.postId).toBe(501);
    expect(mocks.ctx.getPost).not.toHaveBeenCalled();
    expect(mocks.release).toHaveBeenCalledWith(mocks.ctx);
});

test("retains a committed session through a failed readback without creating another post", async () => {
    const session: SpacePostUploadSession = { uploads: [] };
    const request = { images, caption: "Caption", spaceId: "self", session };
    const postId = await createCurrentMediaPost(request);
    mocks.ctx.getPost.mockRejectedValueOnce(new Error("Offline"));
    await expect(
        loadCurrentCreatedPost("self", postId, [file]),
    ).rejects.toThrow("Offline");
    expect(await createCurrentMediaPost(request)).toBe(postId);
    const post = await loadCurrentCreatedPost("self", postId, [file]);
    expect(post.postId).toBe(postId);
    expect(mocks.ctx.createMediaPost).toHaveBeenCalledTimes(1);
    expect(mocks.ctx.uploadPostPhotoAsset).toHaveBeenCalledTimes(1);
    expect(mocks.ctx.getPost).toHaveBeenNthCalledWith(1, "self", 501n, "self");
    expect(mocks.ctx.getPost).toHaveBeenNthCalledWith(2, "self", 501n, "self");
});

test("hydrates a published post from its uploaded previews without another media download", async () => {
    const post = await loadCurrentCreatedPost("self", 501, [file]);
    expect(post.imageUrl).toBe("blob:preview");
    expect(post.photos?.[0]).toMatchObject({
        imageUrl: "blob:preview",
        imageAsset: asset,
    });
    expect(mocks.cacheMedia).toHaveBeenCalledWith("self:photo-1", file);
    expect(mocks.ctx.downloadPostAsset).not.toHaveBeenCalled();
    expect(mocks.cachePost).toHaveBeenCalledWith("self", post);
});

test("a cache failure after creation does not discard the saved post ID", async () => {
    const session: SpacePostUploadSession = { uploads: [] };
    const request = { images, caption: "Caption", spaceId: "self", session };
    const postId = await createCurrentMediaPost(request);
    mocks.cacheMedia.mockRejectedValueOnce(new Error("Cache unavailable"));
    await expect(
        loadCurrentCreatedPost("self", postId, [file]),
    ).rejects.toThrow("Cache unavailable");
    expect(await createCurrentMediaPost(request)).toBe(postId);
    expect(mocks.ctx.createMediaPost).toHaveBeenCalledTimes(1);
});

test("a rejected creation is still reported as a failure", async () => {
    mocks.ctx.createMediaPost.mockRejectedValue(
        new Error("Post limit reached"),
    );
    const session: SpacePostUploadSession = { uploads: [] };
    await expect(
        createCurrentMediaPost({
            images,
            caption: "Caption",
            spaceId: "self",
            session,
        }),
    ).rejects.toThrow("Post limit reached");
    expect(session.postId).toBeUndefined();
    expect(mocks.ctx.getPost).not.toHaveBeenCalled();
});
