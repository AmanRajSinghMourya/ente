import "dart:async";

import "package:ente_components/ente_components.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:photos/core/configuration.dart";
import "package:photos/emergency/components/email_action_sheet.dart";
import "package:photos/emergency/components/trusted_contact_sheet.dart";
import "package:photos/emergency/emergency_service.dart";
import "package:photos/emergency/model.dart";
import "package:photos/emergency/other_contact_page.dart";
import "package:photos/emergency/select_contact_page.dart";
import "package:photos/generated/l10n.dart";
import "package:photos/l10n/l10n.dart";
import "package:photos/services/contacts/contact_identity_resolver.dart";
import "package:photos/ui/sharing/user_avator_widget.dart";

class EmergencyPage extends StatefulWidget {
  const EmergencyPage({super.key});

  @override
  State<EmergencyPage> createState() => _EmergencyPageState();
}

class _EmergencyPageState extends State<EmergencyPage> {
  late int currentUserID;
  EmergencyInfo? info;
  bool _hasLoadError = false;
  bool _isFetching = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    currentUserID = Configuration.instance.getUserID()!;
    Future.delayed(const Duration(seconds: 0), () async {
      unawaited(_fetchData());
    });
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        unawaited(_fetchData(showError: false));
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<bool> _fetchData({
    bool showError = true,
    bool waitForFreshResult = false,
  }) async {
    if (_isFetching) {
      if (!waitForFreshResult) {
        return false;
      }
      while (_isFetching) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (!mounted) return false;
      }
    }
    _isFetching = true;
    try {
      final result = await EmergencyContactService.instance.getInfo();
      if (mounted) {
        setState(() {
          info = result;
          _hasLoadError = false;
        });
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      if (info == null) {
        setState(() {
          _hasLoadError = true;
        });
      } else if (showError) {
        await showLegacyErrorSheet(context, error: e);
      }
      return false;
    } finally {
      _isFetching = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    final l10n = context.l10n;
    final List<EmergencyContact> othersTrustedContacts =
        info?.othersEmergencyContact ?? [];
    final List<EmergencyContact> trustedContacts = info?.contacts ?? [];

    return Scaffold(
      backgroundColor: colors.backgroundBase,
      body: AppBarComponent(
        title: l10n.legacy,
        backgroundColor: colors.backgroundBase,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l10n.legacyPageDesc,
                style: TextStyles.body.copyWith(color: colors.textLight),
              ),
            ),
          ),
          if (info == null && !_hasLoadError)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: CircularProgressIndicator(color: colors.primary),
              ),
            ),
          if (info == null && _hasLoadError)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.all(Spacing.xl),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      AppLocalizations.of(context).somethingWentWrong,
                      textAlign: TextAlign.center,
                      style: TextStyles.body.copyWith(color: colors.textLight),
                    ),
                    const SizedBox(height: Spacing.lg),
                    ButtonComponent(
                      label: AppLocalizations.of(context).retry,
                      shouldShowSuccessState: false,
                      onTap: () => _fetchData(waitForFreshResult: true),
                    ),
                  ],
                ),
              ),
            ),
          if (info != null && info!.recoverSessions.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.only(
                top: Spacing.xl,
                left: Spacing.lg,
                right: Spacing.lg,
              ),
              sliver: SliverToBoxAdapter(
                child: Column(
                  children: [
                    _WarningBanner(text: l10n.recoveryWarning),
                    const SizedBox(height: Spacing.lg),
                    MenuGroupComponent(
                      showDividers: true,
                      items: info!.recoverSessions
                          .map((recoverSession) {
                            final emergencyUser =
                                recoverSession.emergencyContact;
                            return MenuComponent(
                              title: resolveDisplayName(emergencyUser),
                              titleColor: colors.warning,
                              leading: UserAvatarWidget(
                                emergencyUser,
                                type: AvatarType.medium,
                                currentUserID: currentUserID,
                              ),
                              trailing: _buildTrailingWidget(
                                showWarning: false,
                              ),
                              onTap: () =>
                                  showRejectRecoveryDialog(recoverSession),
                            );
                          })
                          .toList(growable: false),
                    ),
                  ],
                ),
              ),
            ),
          if (info != null)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.lg,
                Spacing.xl,
                Spacing.lg,
                Spacing.sm,
              ),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (trustedContacts.isNotEmpty) ...[
                      _SectionTitle(title: l10n.trustedContacts),
                      const SizedBox(height: Spacing.sm),
                      MenuGroupComponent(
                        showDividers: true,
                        items: trustedContacts
                            .map((contact) {
                              final emergencyUser = contact.emergencyContact;
                              return MenuComponent(
                                title: resolveDisplayName(emergencyUser),
                                subtitle: _contactStatusText(contact),
                                titleColor: contact.isPendingInvite()
                                    ? colors.caution
                                    : colors.textBase,
                                leading: UserAvatarWidget(
                                  emergencyUser,
                                  type: AvatarType.medium,
                                  currentUserID: currentUserID,
                                ),
                                trailing: _buildTrailingWidget(
                                  showWarning: contact.isPendingInvite(),
                                ),
                                onTap: () =>
                                    showRevokeOrRemoveDialog(context, contact),
                              );
                            })
                            .toList(growable: false),
                      ),
                      const SizedBox(height: Spacing.xl),
                    ],
                    if (trustedContacts.isEmpty) ...[
                      Center(
                        child: Image.asset(
                          "assets/legacy.png",
                          width: 200,
                          height: 200,
                        ),
                      ),
                      Text(
                        l10n.legacyPageDesc2,
                        style: TextStyles.body.copyWith(
                          color: colors.textLight,
                        ),
                      ),
                      const SizedBox(height: Spacing.lg),
                    ],
                    ButtonComponent(
                      label: l10n.addTrustedContact,
                      shouldShowSuccessState: false,
                      onTap: _addTrustedContact,
                    ),
                  ],
                ),
              ),
            ),
          if (info != null && info!.othersEmergencyContact.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.lg,
                Spacing.xl,
                Spacing.lg,
                Spacing.xxl,
              ),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const DividerComponent(),
                    const SizedBox(height: Spacing.lg),
                    _SectionTitle(title: l10n.legacyAccounts),
                    const SizedBox(height: Spacing.sm),
                    MenuGroupComponent(
                      showDividers: true,
                      items: othersTrustedContacts
                          .map((contact) {
                            final emergencyUser = contact.user;
                            return MenuComponent(
                              title: resolveDisplayName(emergencyUser),
                              subtitle: _legacyAccountStatusText(contact),
                              titleColor: contact.isPendingInvite()
                                  ? colors.caution
                                  : colors.textBase,
                              leading: UserAvatarWidget(
                                emergencyUser,
                                type: AvatarType.medium,
                                currentUserID: currentUserID,
                              ),
                              trailing: _buildTrailingWidget(
                                showWarning: contact.isPendingInvite(),
                              ),
                              onTap: () => _openLegacyAccount(contact),
                            );
                          })
                          .toList(growable: false),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _contactStatusText(EmergencyContact contact) {
    return contact.isPendingInvite()
        ? context.strings.trustedContactStatusPending
        : context.strings.trustedContactStatusAccepted;
  }

  String _legacyAccountStatusText(EmergencyContact contact) {
    if (contact.isPendingInvite()) {
      return context.strings.trustedContactStatusPending;
    }
    return switch (_recoverySessionFor(contact)?.status) {
      "WAITING" => context.l10n.recoveryInitiated,
      "READY" => context.l10n.recoverAccount,
      _ => context.strings.trustedContactStatusAccepted,
    };
  }

  RecoverySessions? _recoverySessionFor(EmergencyContact contact) {
    final recoverySessions = info?.othersRecoverySession;
    if (recoverySessions == null) {
      return null;
    }
    for (final session in recoverySessions) {
      if (session.user.id == contact.user.id) {
        return session;
      }
    }
    return null;
  }

  Future<void> _addTrustedContact() async {
    final result = await showAddContactSheet(context, emergencyInfo: info!);
    if (result == true && mounted) {
      await _fetchData(showError: false, waitForFreshResult: true);
    }
  }

  Future<void> _openLegacyAccount(EmergencyContact contact) async {
    if (contact.isPendingInvite()) {
      await showAcceptOrDeclineDialog(context, contact);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            OtherContactPage(contact: contact, emergencyInfo: info!),
      ),
    );
    if (mounted) {
      await _fetchData(showError: false, waitForFreshResult: true);
    }
  }

  Widget _buildTrailingWidget({required bool showWarning}) {
    final colors = context.componentColors;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showWarning) ...[
          Image.asset("assets/warning-yellow.png", width: 20, height: 20),
          const SizedBox(width: Spacing.xs),
        ],
        Icon(
          Icons.chevron_right_rounded,
          color: colors.textLight,
          size: IconSizes.medium,
        ),
      ],
    );
  }

  Future<void> showRevokeOrRemoveDialog(
    BuildContext context,
    EmergencyContact contact,
  ) async {
    final actionResult = await showTrustedContactSheet(
      context,
      contact: contact,
    );
    if (actionResult == null) {
      return;
    }

    if (actionResult.action == TrustedContactAction.revoke) {
      final isPending = contact.isPendingInvite();
      if (!context.mounted) return;
      final confirmed = await showLegacyAlertSheet<bool>(
        context,
        title: isPending
            ? context.l10n.cancelInvite
            : context.l10n.removeContact,
        message: isPending
            ? context.l10n.cancelInviteDesc
            : context.l10n.removeContactDesc,
        actions: [
          ButtonComponent(
            variant: ButtonComponentVariant.critical,
            label: isPending
                ? context.l10n.revokeInvite
                : context.l10n.removeContact,
            onTap: () async => Navigator.of(context).pop(true),
            shouldShowSuccessState: false,
          ),
        ],
      );

      if (confirmed == true) {
        try {
          await EmergencyContactService.instance.updateContact(
            contact,
            ContactState.userRevokedContact,
          );
          info?.contacts.remove(contact);
          if (mounted) {
            setState(() {});
            await _fetchData(showError: false, waitForFreshResult: true);
          }
        } catch (e) {
          if (!context.mounted) return;
          await showLegacyErrorSheet(context, error: e);
        }
      }
      return;
    }

    final selectedDays = actionResult.selectedDays;
    if (actionResult.action != TrustedContactAction.updateTime ||
        selectedDays == null) {
      return;
    }

    try {
      final success = await EmergencyContactService.instance
          .updateRecoveryNotice(contact, selectedDays);
      if (success) {
        final updatedContact = contact.copyWith(
          recoveryNoticeInDays: selectedDays,
        );
        final index = info?.contacts.indexWhere(
          (element) =>
              element.user.id == contact.user.id &&
              element.emergencyContact.id == contact.emergencyContact.id,
        );
        if (index != null && index >= 0) {
          info?.contacts[index] = updatedContact;
        }
        if (mounted) {
          setState(() {});
          await _fetchData(showError: false, waitForFreshResult: true);
        }
      } else {
        if (mounted) {
          if (!context.mounted) return;
          await showLegacyAlertSheet(
            context,
            title: context.l10n.cannotUpdateRecoveryTime,
            message: context.l10n.cannotUpdateRecoveryTimeMessage,
          );
        }
      }
    } catch (e) {
      if (!context.mounted) return;
      await showLegacyErrorSheet(context, error: e);
    }
  }

  Future<void> showAcceptOrDeclineDialog(
    BuildContext context,
    EmergencyContact contact,
  ) async {
    final result = await showEmailActionSheet<String>(
      context,
      email: contact.user.email,
      message: AppLocalizations.of(
        context,
      ).legacyInvite(email: contact.user.email),
      buttons: [
        ButtonComponent(
          label: AppLocalizations.of(context).acceptTrustInvite,
          shouldShowSuccessState: false,
          onTap: () async => Navigator.of(context).pop("accept"),
        ),
        ButtonComponent(
          variant: ButtonComponentVariant.tertiaryCritical,
          label: AppLocalizations.of(context).declineTrustInvite,
          shouldShowSuccessState: false,
          onTap: () async => Navigator.of(context).pop("decline"),
        ),
      ],
    );

    final state = switch (result) {
      "accept" => ContactState.contactAccepted,
      "decline" => ContactState.contactDenied,
      _ => null,
    };
    if (state == null) {
      return;
    }
    try {
      await EmergencyContactService.instance.updateContact(contact, state);
      info?.othersEmergencyContact.remove(contact);
      if (state == ContactState.contactAccepted) {
        info?.othersEmergencyContact.add(
          contact.copyWith(state: ContactState.contactAccepted),
        );
      }
      if (mounted) {
        setState(() {});
        await _fetchData(showError: false, waitForFreshResult: true);
      }
    } catch (e) {
      if (!context.mounted) return;
      await showLegacyErrorSheet(context, error: e);
    }
  }

  Future<void> showRejectRecoveryDialog(RecoverySessions session) async {
    final emergencyContactEmail = session.emergencyContact.email;

    final confirmed = await showEmailActionSheet<bool>(
      context,
      email: emergencyContactEmail,
      message: context.l10n.recoveryWarningBody(email: emergencyContactEmail),
      buttons: [
        ButtonComponent(
          variant: ButtonComponentVariant.critical,
          label: context.l10n.rejectRecovery,
          shouldShowSuccessState: false,
          onTap: () async => Navigator.of(context).pop(true),
        ),
        if (kDebugMode)
          ButtonComponent(
            variant: ButtonComponentVariant.secondary,
            label: "Approve recovery (to be removed)",
            shouldShowSuccessState: false,
            onTap: () async {
              Navigator.of(context).pop();
              try {
                await EmergencyContactService.instance.approveRecovery(session);
                if (mounted) {
                  await _fetchData(showError: false, waitForFreshResult: true);
                }
              } catch (e) {
                if (!mounted) return;
                await showLegacyErrorSheet(context, error: e);
              }
            },
          ),
      ],
    );

    if (confirmed == true) {
      try {
        await EmergencyContactService.instance.rejectRecovery(session);
        info?.recoverSessions.removeWhere(
          (element) => element.id == session.id,
        );
        if (mounted) {
          setState(() {});
          await _fetchData(showError: false, waitForFreshResult: true);
        }
      } catch (e) {
        if (!mounted) return;
        await showLegacyErrorSheet(context, error: e);
      }
    }
  }
}

class _WarningBanner extends StatelessWidget {
  final String text;

  const _WarningBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.fillLight,
        borderRadius: BorderRadius.circular(Radii.button),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Row(
          children: [
            Image.asset(
              "assets/emergency-warning.png",
              width: IconSizes.large,
              height: IconSizes.large,
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Text(
                text,
                style: TextStyles.bodyBold.copyWith(color: colors.caution),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: TextStyles.bodyBold.copyWith(
        color: context.componentColors.textLight,
      ),
    );
  }
}
