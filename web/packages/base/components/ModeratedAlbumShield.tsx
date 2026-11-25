import { Shield01Icon } from "@hugeicons/core-free-icons";
import { HugeiconsIcon } from "@hugeicons/react";
import { IconButton, Tooltip } from "@mui/material";
import { t } from "i18next";

export const ModeratedAlbumShield = () => (
    <Tooltip title={t("moderated_album")} enterTouchDelay={0}>
        <IconButton
            size="small"
            aria-label={t("moderated_album")}
            sx={{ ml: 0.5, flexShrink: 0, color: "inherit" }}
        >
            <HugeiconsIcon icon={Shield01Icon} size={20} strokeWidth={1.8} />
        </IconButton>
    </Tooltip>
);
