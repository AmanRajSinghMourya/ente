import { authPageConfig } from "@/auth-page-config";
import { shareExtensionUnlock } from "@/services/extension";
import { authLogout } from "@/services/logout";
import "@fontsource-variable/inter";
import "@fontsource-variable/outfit";
import { CssBaseline } from "@mui/material";
import { ThemeProvider } from "@mui/material/styles";
import { AuthPageProvider } from "ente-accounts/components/auth/AuthPageProvider";
import { savedLocalUser } from "ente-accounts/services/accounts-db";
import { isExtension, staticAppTitle } from "ente-base/app";
import { CustomHead } from "ente-base/components/Head";
import {
    LoadingIndicator,
    TranslucentLoadingOverlay,
} from "ente-base/components/loaders";
import { AttributedMiniDialog } from "ente-base/components/MiniDialog";
import { useAttributedMiniDialog } from "ente-base/components/utils/dialog";
import {
    useIsRouteChangeInProgress,
    useSetupI18n,
    useSetupLogs,
} from "ente-base/components/utils/hooks-app";
import { authTheme } from "ente-base/components/utils/theme";
import { BaseContext, deriveBaseContext } from "ente-base/context";
import log from "ente-base/log";
import { logStartupBanner } from "ente-base/log-web";
import { t } from "i18next";
import type { AppProps } from "next/app";
import { useRouter } from "next/router";
import React, { useCallback, useEffect, useMemo } from "react";

const App: React.FC<AppProps> = ({ Component, pageProps }) => {
    useSetupLogs();

    const isI18nReady = useSetupI18n();
    const isChangingRoute = useIsRouteChangeInProgress();
    const { showMiniDialog, miniDialogProps } = useAttributedMiniDialog();

    useEffect(() => {
        logStartupBanner(savedLocalUser()?.id);
    }, []);

    const { events: routerEvents } = useRouter();

    useEffect(() => {
        if (!isExtension) return;
        const handleExtensionRouteChange = (url: string) => {
            const { pathname, search, hash } = new URL(
                url,
                window.location.href,
            );
            if (pathname === "/auth") {
                void shareExtensionUnlock().catch((error: unknown) =>
                    log.error("Failed to unlock the extension popup", error),
                );
            }
            if (pathname.endsWith(".html")) return;
            const file = pathname == "/" ? "/index.html" : `${pathname}.html`;
            window.history.replaceState(
                window.history.state,
                "",
                file + search + hash,
            );
        };
        routerEvents.on("routeChangeComplete", handleExtensionRouteChange);
        return () =>
            routerEvents.off("routeChangeComplete", handleExtensionRouteChange);
    }, [routerEvents]);

    const logout = useCallback(() => void authLogout(), []);

    const baseContext = useMemo(
        () => deriveBaseContext({ logout, showMiniDialog }),
        [logout, showMiniDialog],
    );

    const title = isI18nReady ? t("title_auth") : staticAppTitle;

    return (
        <ThemeProvider theme={authTheme}>
            <CustomHead title={title} />
            <CssBaseline enableColorScheme />
            <AttributedMiniDialog {...miniDialogProps} />

            <BaseContext value={baseContext}>
                <AuthPageProvider value={authPageConfig}>
                    {!isI18nReady ? (
                        <LoadingIndicator />
                    ) : (
                        <>
                            {isChangingRoute && <TranslucentLoadingOverlay />}
                            <Component {...pageProps} />
                        </>
                    )}
                </AuthPageProvider>
            </BaseContext>
        </ThemeProvider>
    );
};

export default App;
