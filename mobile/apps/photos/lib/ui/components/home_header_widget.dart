import "package:ente_components/ente_components.dart";
import "package:ente_strings/ente_strings.dart";
import 'package:flutter/material.dart';
import "package:hugeicons/hugeicons.dart";
import "package:photos/service_locator.dart";
import "package:photos/ui/common/backup_flow_helper.dart";
import 'package:photos/ui/components/buttons/icon_button_widget.dart';
import "package:photos/ui/viewer/album_slideshow/album_slideshow.dart";
import "package:photos/ui/viewer/gallery/gallery_app_bar_actions.dart";
import "package:photos/ui/viewer/gallery/state/gallery_context_state.dart";

enum _HomeHeaderAction { slideshow, addPhotos }

class HomeHeaderWidget extends StatefulWidget {
  final Widget centerWidget;
  const HomeHeaderWidget({required this.centerWidget, super.key});

  @override
  State<HomeHeaderWidget> createState() => _HomeHeaderWidgetState();
}

class _HomeHeaderWidgetState extends State<HomeHeaderWidget> {
  @override
  Widget build(BuildContext context) {
    final showAddAlbumAction =
        !isLocalGalleryMode || permissionService.hasGrantedLimitedPermissions();
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButtonWidget(
              iconButtonType: IconButtonType.primary,
              iconWidget: const HugeIcon(icon: HugeIcons.strokeRoundedMenu01),
              onTap: () {
                Scaffold.of(context).openDrawer();
              },
            ),
          ],
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: widget.centerWidget,
        ),
        isLocalGalleryMode
            ? Padding(
                padding: const EdgeInsets.all(6),
                child: galleryAppBarPopupMenuAction<_HomeHeaderAction>(
                  tooltip: context.strings.more,
                  icon: const HugeIcon(
                    icon: HugeIcons.strokeRoundedMoreVertical,
                  ),
                  optionsBuilder: () => [
                    EntePopupMenuOption(
                      value: _HomeHeaderAction.slideshow,
                      label: context.strings.slideshow,
                      leadingWidget: galleryAppBarMenuIcon(
                        HugeIcons.strokeRoundedPresentation03,
                        context.componentColors.iconColor,
                      ),
                    ),
                    if (showAddAlbumAction)
                      EntePopupMenuOption(
                        value: _HomeHeaderAction.addPhotos,
                        label: context.strings.addPhotos,
                        leadingWidget: galleryAppBarMenuIcon(
                          HugeIcons.strokeRoundedImageAdd01,
                          context.componentColors.iconColor,
                        ),
                      ),
                  ],
                  onSelected: (action) async {
                    if (action == _HomeHeaderAction.addPhotos) {
                      await handleFullPermissionBackupFlow(context);
                      return;
                    }
                    final files = await GalleryContextState.of(
                      context,
                    )!.loadAllFiles!();
                    if (!context.mounted) return;
                    await showAlbumSlideshow(
                      context,
                      files: files,
                      title: context.strings.slideshow,
                    );
                  },
                ),
              )
            : showAddAlbumAction
            ? IconButtonWidget(
                iconWidget: const HugeIcon(
                  icon: HugeIcons.strokeRoundedUpload01,
                ),
                iconButtonType: IconButtonType.primary,
                onTap: () async => handleFullPermissionBackupFlow(context),
              )
            : const SizedBox(width: 48, height: 48),
      ],
    );
  }
}
