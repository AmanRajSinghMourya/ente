import { Box } from "@mui/material";
import { createSpaceVideoContent } from "components/PostVideoContent";
import { registerFeedVideo } from "components/feed-video-playback";
import React, { useEffect, useRef } from "react";
import type { SpacePostAssetURLLoader, SpacePostVideo } from "services/space";

export const SpaceInlinePostVideo: React.FC<{
    imageUrl: string;
    video: SpacePostVideo;
    isActive: boolean;
    muted: boolean;
    onLoadVideo?: SpacePostAssetURLLoader;
}> = ({ imageUrl, video, isActive, muted, onLoadVideo }) => {
    const root = useRef<HTMLDivElement>(null);
    const player = useRef<
        ReturnType<typeof createSpaceVideoContent> | undefined
    >(undefined);
    const playback = useRef<ReturnType<typeof registerFeedVideo>>(undefined);

    useEffect(() => {
        const container = root.current!;
        const content = createSpaceVideoContent(
            { imageUrl, video },
            onLoadVideo,
            {
                inline: true,
                onTogglePlayback: (play) => {
                    if (play) registration.play();
                    else registration.pause();
                },
            },
        );
        const registration = registerFeedVideo(container, content);
        playback.current = registration;
        player.current = content;
        container.append(content.element);
        return () => {
            registration.unregister();
            content.destroy();
            content.element.remove();
            player.current = undefined;
            playback.current = undefined;
        };
    }, [imageUrl, onLoadVideo, video]);

    useEffect(() => {
        const content = player.current!;
        content.video.tabIndex = isActive ? 0 : -1;
        content.element.querySelector("button")!.tabIndex = isActive ? 0 : -1;
        playback.current!.setActive(isActive);
    }, [imageUrl, isActive, onLoadVideo, video]);

    useEffect(() => {
        player.current!.video.muted = muted;
    }, [imageUrl, muted, onLoadVideo, video]);

    return (
        <Box ref={root} sx={{ position: "absolute", inset: 0, zIndex: 1 }} />
    );
};
