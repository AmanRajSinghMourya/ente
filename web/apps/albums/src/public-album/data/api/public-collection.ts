import {
    authenticatedPublicAlbumsRequestHeaders,
    ensureOk,
    isHTTP401Error,
    type PublicAlbumsCredentials,
} from "ente-base/http";
import { apiURL } from "ente-base/origins";
import {
    decryptRemoteCollection,
    type Collection,
} from "ente-media/collection";
import { decryptRemoteFile, type EnteFile } from "ente-media/file";
import {
    getPublicCollectionDiff,
    getPublicCollectionInfo,
} from "ente-media/public-albums";
import {
    removePublicCollectionAccessTokenJWT,
    removePublicCollectionFiles,
    removePublicCollectionLastSyncTime,
    savedPublicCollectionFileState,
    saveLastPublicCollectionReferralCode,
    savePublicCollection,
    savePublicCollectionFiles,
} from "../storage/public-albums-fdb";

export const removePendingFile = async (
    credentials: PublicAlbumsCredentials,
    fileID: number,
) => {
    const res = await fetch(
        await apiURL(`/public-collection/pending-files/${fileID}`),
        {
            method: "DELETE",
            headers: authenticatedPublicAlbumsRequestHeaders(credentials),
        },
    );
    ensureOk(res);
};

export const pullCollection = async (
    credentials: PublicAlbumsCredentials,
    collectionKey: string,
): Promise<{
    collection: Collection;
    referralCode: string;
    linkDeviceToken?: string;
}> => {
    // The collection key comes from the URL fragment. Never send it to remote.
    const {
        collection: remoteCollection,
        referralCode,
        linkDeviceToken,
    } = await getPublicCollectionInfo(credentials);

    const collection = await decryptRemoteCollection(
        remoteCollection,
        collectionKey,
    );

    await savePublicCollection(collection);
    await saveLastPublicCollectionReferralCode(referralCode);

    return { collection, referralCode, linkDeviceToken };
};

export const pullPublicCollectionFiles = async (
    credentials: PublicAlbumsCredentials,
    collection: Collection,
    // Files passed here have no defined order.
    onSetFiles: (files: EnteFile[]) => void,
    anonUserID?: string,
) => {
    const { accessToken } = credentials;

    const saved = await savedPublicCollectionFileState(accessToken);
    const sameIdentity = saved.anonUserID === anonUserID;
    let sinceTime = sameIdentity ? saved.sinceTime : 0;

    // Remote advances collection.updationTime whenever a file changes.
    if (sinceTime == collection.updationTime) return;

    const files = sameIdentity ? saved.files : [];
    const filesByID = new Map(files.map((f) => [f.id, f]));
    let callbackInvoked = false;

    while (true) {
        const { diff, hasMore } = await getPublicCollectionDiff(
            credentials,
            sinceTime,
        );
        if (!diff.length) {
            // An empty first page must still publish the cached files.
            if (!callbackInvoked) {
                if (!sameIdentity) {
                    await savePublicCollectionFiles(
                        accessToken,
                        files,
                        sinceTime,
                        anonUserID,
                    );
                }
                onSetFiles(files);
            }
            break;
        }
        for (const change of diff) {
            sinceTime = Math.max(sinceTime, change.updationTime);
            if (change.isDeleted) {
                filesByID.delete(change.id);
            } else {
                filesByID.set(
                    change.id,
                    await decryptRemoteFile(change, collection.key),
                );
            }
        }

        const updatedFiles = [...filesByID.values()];
        await savePublicCollectionFiles(
            accessToken,
            updatedFiles,
            sinceTime,
            anonUserID,
        );
        onSetFiles(updatedFiles);
        callbackInvoked = true;

        if (!hasMore) break;
    }
};

export const isGuestIdentityRejected = async (
    credentials: PublicAlbumsCredentials,
    collection: Collection,
) => {
    try {
        await getPublicCollectionDiff(
            { ...credentials, anonUserToken: undefined },
            collection.updationTime,
        );
        return true;
    } catch (e) {
        if (isHTTP401Error(e)) return false;
        throw e;
    }
};

export const isGuestIdentityValid = async (
    credentials: PublicAlbumsCredentials,
    collection: Collection,
) => {
    try {
        await getPublicCollectionDiff(credentials, collection.updationTime);
        return true;
    } catch (e) {
        if (isHTTP401Error(e)) {
            return !(await isGuestIdentityRejected(credentials, collection));
        }
        throw e;
    }
};

export const removePublicCollectionFileData = async (accessToken: string) => {
    await Promise.all([
        removePublicCollectionAccessTokenJWT(accessToken),
        removePublicCollectionLastSyncTime(accessToken),
        removePublicCollectionFiles(accessToken),
    ]);
};
