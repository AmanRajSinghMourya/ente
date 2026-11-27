import { accountLogout } from "ente-accounts/services/logout";
import { isExtension } from "ente-base/app";
import log from "ente-base/log";
import { clearAuthenticatedSession } from "./authenticated-session";
import { clearExtensionUnlock, isExtensionPopup } from "./extension";

export const authLogout = async () => {
    clearAuthenticatedSession();
    if (isExtension) {
        try {
            await clearExtensionUnlock();
        } catch (error) {
            log.error("Failed to clear the extension unlock", error);
        }
    }
    await accountLogout();
    if (isExtensionPopup()) {
        window.location.reload();
        return;
    }
    window.location.replace(isExtension ? "/index.html" : "/");
};
