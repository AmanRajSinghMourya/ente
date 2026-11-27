import { isExtension } from "ente-base/app";
import { masterKeyFromSession } from "./account-keys";

declare const chrome: {
    runtime: { getURL: (path: string) => string };
    storage: {
        session: {
            get: (key: string) => Promise<Record<string, unknown>>;
            set: (items: Record<string, unknown>) => Promise<void>;
            remove: (key: string) => Promise<void>;
        };
    };
    tabs: { create: (options: { url: string }) => Promise<unknown> };
};

export const isExtensionPopup = () =>
    isExtension &&
    new URLSearchParams(window.location.search).get("popup") === "1";

export const openExtensionSignIn = async () => {
    await chrome.storage.session.set({ signInPending: true });
    await chrome.tabs.create({ url: chrome.runtime.getURL("index.html") });
};

export const shareExtensionUnlock = async () => {
    const { signInPending } = await chrome.storage.session.get("signInPending");
    if (!signInPending) return;
    const masterKey = await masterKeyFromSession();
    if (!masterKey) return;
    await chrome.storage.session.set({ masterKey });
    await chrome.storage.session.remove("signInPending");
};

export const extensionMasterKey = async () => {
    const { masterKey } = await chrome.storage.session.get("masterKey");
    return typeof masterKey === "string" ? masterKey : undefined;
};

export const clearExtensionUnlock = () =>
    chrome.storage.session.remove("masterKey");
