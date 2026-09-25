import 'package:ente_components/ente_components.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AppVersionWidget extends StatefulWidget {
  const AppVersionWidget({super.key, this.onTap, this.showDot = false});

  final VoidCallback? onTap;
  final bool showDot;

  @override
  State<AppVersionWidget> createState() => _AppVersionWidgetState();
}

class _AppVersionWidgetState extends State<AppVersionWidget> {
  late final Future<PackageInfo> _packageInfo;

  @override
  void initState() {
    super.initState();
    _packageInfo = PackageInfo.fromPlatform();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: _packageInfo,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox.shrink();
        }

        final version = context.strings.appVersion(
          versionValue: snapshot.data!.version,
        );
        final versionText = Text(
          version,
          style: TextStyles.mini.copyWith(
            color: context.componentColors.textLight,
          ),
        );

        return Padding(
          padding: EdgeInsets.symmetric(
            vertical: widget.onTap == null ? Spacing.xl : Spacing.xs,
          ),
          child: Center(
            child: widget.onTap == null
                ? versionText
                : Material(
                    color: Colors.transparent,
                    child: Semantics(
                      button: true,
                      label: '$version. ${context.strings.whatsNew}',
                      child: InkWell(
                        onTap: widget.onTap,
                        borderRadius: BorderRadius.circular(Radii.sm),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Spacing.lg,
                          ),
                          child: SizedBox(
                            height: 48,
                            child: Center(
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  ExcludeSemantics(child: versionText),
                                  if (widget.showDot)
                                    Positioned(
                                      top: -5,
                                      right: -10,
                                      child: Container(
                                        width: 8,
                                        height: 8,
                                        decoration: BoxDecoration(
                                          color:
                                              context.componentColors.primary,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }
}
