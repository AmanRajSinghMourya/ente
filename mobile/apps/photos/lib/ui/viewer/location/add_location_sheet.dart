import "package:ente_components/ente_components.dart";
import 'package:flutter/material.dart';
import "package:hugeicons/hugeicons.dart";
import "package:intl/intl.dart";
import "package:modal_bottom_sheet/modal_bottom_sheet.dart";
import "package:photos/core/constants.dart";
import "package:photos/generated/l10n.dart";
import "package:photos/models/location/location.dart";
import "package:photos/service_locator.dart";
import 'package:photos/states/location_state.dart';
import "package:photos/theme/colors.dart";
import "package:photos/ui/common/loading_widget.dart";
import "package:photos/ui/components/divider_widget.dart";
import 'package:photos/ui/components/keyboard/keyboard_oveylay.dart';
import "package:photos/ui/components/keyboard/keyboard_top_button.dart";
import 'package:photos/ui/viewer/location/dynamic_location_gallery_widget.dart';
import "package:photos/ui/viewer/location/radius_picker_widget.dart";

void showAddLocationSheet(
  BuildContext context,
  Location coordinates, {
  String name = '',
  double radius = defaultRadiusValue,
}) {
  showBarModalBottomSheet(
    context: context,
    builder: (context) {
      return LocationTagStateProvider(
        centerPoint: coordinates,
        AddLocationSheet(radius: radius, name: name),
        radius: radius,
      );
    },
    shape: const RoundedRectangleBorder(
      side: BorderSide(width: 0),
      borderRadius: BorderRadius.vertical(top: Radius.circular(5)),
    ),
    topControl: const SizedBox.shrink(),
    backgroundColor: context.componentColors.backgroundBase,
    barrierColor: backdropFaintDark,
  );
}

class AddLocationSheet extends StatefulWidget {
  final double radius;
  final String name;
  const AddLocationSheet({
    super.key,
    this.radius = defaultRadiusValue,
    this.name = '',
  });

  @override
  State<AddLocationSheet> createState() => _AddLocationSheetState();
}

class _AddLocationSheetState extends State<AddLocationSheet> {
  //The value of this notifier has no significance.
  //When memoriesCountNotifier is null, we show the loading widget in the
  //memories count section which also means the gallery is loading.
  final ValueNotifier<int?> _memoriesCountNotifier = ValueNotifier(null);

  final ValueNotifier<bool> _cancelNotifier = ValueNotifier(false);
  late ValueNotifier<double> _selectedRadiusNotifier;
  final _focusNode = FocusNode();
  final _textEditingController = TextEditingController();
  late final ValueNotifier<bool> _isEmptyNotifier;
  Widget? _keyboardTopButtons;

  @override
  void initState() {
    _textEditingController.text = widget.name;
    _isEmptyNotifier = ValueNotifier(widget.name.isEmpty);
    _focusNode.addListener(_focusNodeListener);
    _selectedRadiusNotifier = ValueNotifier(widget.radius);
    _selectedRadiusNotifier.addListener(_selectedRadiusListener);

    super.initState();
  }

  @override
  void dispose() {
    _focusNode.removeListener(_focusNodeListener);
    _cancelNotifier.dispose();
    _selectedRadiusNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 32, 0, 8),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.xs,
              Spacing.lg,
              Spacing.lg,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                AppLocalizations.of(context).addLocation,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyles.h2.copyWith(color: colors.textBase),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(
                decelerationRate: ScrollDecelerationRate.fast,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextInputComponent(
                                controller: _textEditingController,
                                hintText: AppLocalizations.of(
                                  context,
                                ).locationName,
                                focusNode: _focusNode,
                                cancelNotifier: _cancelNotifier,
                                popNavAfterSubmission: false,
                                shouldUnfocusOnClearOrSubmit: true,
                                isClearable: true,
                                textCapitalization: TextCapitalization.words,
                                isEmptyNotifier: _isEmptyNotifier,
                              ),
                            ),
                            const SizedBox(width: 8),
                            ValueListenableBuilder(
                              valueListenable: _isEmptyNotifier,
                              builder: (context, bool value, _) {
                                return IconButtonComponent(
                                  variant: IconButtonComponentVariant.green,
                                  tooltip: AppLocalizations.of(
                                    context,
                                  ).addLocationButton,
                                  icon: const HugeIcon(
                                    icon: HugeIcons.strokeRoundedPlusSign,
                                  ),
                                  onTap: value
                                      ? null
                                      : () async {
                                          _focusNode.unfocus();
                                          await _addLocationTag();
                                        },
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        RadiusPickerWidget(_selectedRadiusNotifier),
                        if (widget.name.isEmpty) const SizedBox(height: 16),
                        if (widget.name.isEmpty)
                          Text(
                            AppLocalizations.of(
                              context,
                            ).locationTagFeatureDescription,
                            style: TextStyles.body.copyWith(
                              color: colors.textLight,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const DividerWidget(
                    dividerType: DividerType.solid,
                    padding: EdgeInsets.only(top: 24, bottom: 20),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: ValueListenableBuilder(
                        valueListenable: _memoriesCountNotifier,
                        builder: (context, int? value, _) {
                          Widget widget;
                          if (value == null) {
                            widget = EnteLoadingWidget(
                              size: 14,
                              color: colors.textLight,
                              alignment: Alignment.centerLeft,
                              padding: 3,
                            );
                          } else {
                            widget = Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  AppLocalizations.of(context).memoryCount(
                                    count: value,
                                    formattedCount: NumberFormat().format(
                                      value,
                                    ),
                                  ),
                                  style: TextStyles.body.copyWith(
                                    color: colors.textBase,
                                  ),
                                ),
                                if (value > 1000)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      AppLocalizations.of(
                                        context,
                                      ).galleryMemoryLimitInfo,
                                      style: TextStyles.mini.copyWith(
                                        color: colors.textLight,
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          }
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 250),
                              switchInCurve: Curves.easeInOutExpo,
                              switchOutCurve: Curves.easeInOutExpo,
                              child: widget,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  DynamicLocationGalleryWidget(
                    _memoriesCountNotifier,
                    "Add_location",
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addLocationTag() async {
    final locationData = InheritedLocationTagData.of(context);
    final coordinates = locationData.centerPoint;
    final radius = locationData.selectedRadius;

    await locationService.addLocation(
      _textEditingController.text.trim(),
      coordinates,
      radius,
    );
    if (!mounted) return;
    Navigator.pop(context);
  }

  void _focusNodeListener() {
    final bool hasFocus = _focusNode.hasFocus;
    _keyboardTopButtons ??= KeyboardTopButton(
      onDoneTap: _focusNode.unfocus,
      onCancelTap: () {
        _cancelNotifier.value = !_cancelNotifier.value;
      },
    );
    if (hasFocus) {
      KeyboardOverlay.showOverlay(context, _keyboardTopButtons!);
    } else {
      KeyboardOverlay.removeOverlay();
    }
  }

  void _selectedRadiusListener() {
    InheritedLocationTagData.of(
      context,
    ).updateSelectedRadius(_selectedRadiusNotifier.value);
    _memoriesCountNotifier.value = null;
  }
}
