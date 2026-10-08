package email

import (
	"context"
	"fmt"
	"math/big"
	stdtime "time"

	"github.com/ente/museum/pkg/repo"
	"github.com/ente/museum/pkg/utils/email"
	"github.com/ente/museum/pkg/utils/time"
	log "github.com/sirupsen/logrus"
	"github.com/spf13/viper"
)

var sendPhotosStorageWarningEmail = email.SendTemplatedEmailV2

func (c *EmailNotificationController) SendPhotosStorageWarningMails() {
	if c.UserRepo.IsLikelySelfHosted() {
		return
	}
	launch, err := stdtime.Parse(stdtime.RFC3339, viper.GetString("photos-storage-emails.launch-time"))
	if err == nil {
		_, offset := launch.Zone()
		if offset != 0 {
			err = fmt.Errorf("launch-time must be UTC")
		}
	}
	if err != nil {
		log.WithError(err).Error("Skipping Photos storage emails: fixed RFC3339 UTC launch-time required")
		return
	}
	const lockID = "photos_storage_warning_mail_lock"
	if !c.LockController.TryLock(lockID, time.MicrosecondsAfterHours(24)) {
		return
	}
	defer c.LockController.ReleaseLock(lockID)
	ctx := context.Background()
	ids, err := c.UsageRepo.GetPhotosStorageWarningCandidates(ctx, launch.UnixMicro())
	if err != nil {
		log.WithError(err).Error("Failed to fetch Photos storage email candidates")
		return
	}
	processed, sent, failed := 0, 0, 0
	defer func() {
		log.WithFields(log.Fields{"candidates": len(ids), "processed": processed, "sent": sent, "failed": failed, "skipped": processed - sent - failed}).Info("Photos storage email run completed")
	}()
	for _, id := range ids {
		processed++
		state, event, err := c.preparePhotosStorageEmail(ctx, id, launch.UnixMicro())
		logger := log.WithField("user_id", id)
		if err != nil {
			failed++
			logger.WithError(err).Error("Failed to prepare Photos storage email")
			continue
		}
		if event == "" {
			continue
		}
		subject, name := "Your Ente Photos storage is almost full", "photos_storage_warning.html"
		if event == repo.PhotosStorageReminderTemplateID {
			name = "photos_storage_reminder.html"
		}
		full := state.Usage >= state.Allowance
		if full {
			subject = "Your Ente Photos storage is full"
		}
		err = sendPhotosStorageWarningEmail([]string{state.User.Email}, "Ente", "team@ente.com", subject, "ente_base.html", name,
			map[string]interface{}{"Full": full, "UsagePercent": photosStorageUsagePercent(state.Usage, state.Allowance)}, nil)
		if err != nil {
			failed++
			logger.WithError(err).WithField("event", event).Error("Failed to send Photos storage email")
			continue
		}
		sent++
	}
}

func (c *EmailNotificationController) preparePhotosStorageEmail(ctx context.Context, userID, launchTime int64) (repo.PhotosStorageState, string, error) {
	var state repo.PhotosStorageState
	tx, err := c.NotificationHistoryRepo.BeginStorageNotification(ctx, userID)
	if err != nil {
		return state, "", err
	}
	defer tx.Rollback()
	history, err := repo.PhotosStorageHistory(ctx, tx, userID)
	if err != nil {
		return state, "", err
	}
	if history[repo.PhotosStorageReminderTemplateID] > 0 {
		return state, "", nil
	}
	state, err = c.UserRepo.PhotosStorageState(ctx, tx, userID)
	if err != nil {
		return state, "", err
	}
	if !state.Eligible || state.User.CreationTime < launchTime {
		return state, "", nil
	}
	now := time.Microseconds()
	blocked := history[repo.StorageWarningExpiredScheduledDeletionTemplateID] > 0 || history[repo.StorageWarningActiveOverageScheduledDeletionTemplateID] > 0 || history[repo.StorageWarningLoginGraceTemplateID] > 0
	if blocked && !repo.StorageWarningLoginGraceActive(history[repo.StorageWarningLoginGraceTemplateID], now) {
		return state, "", nil
	}
	event := repo.PhotosStorageWarningTemplateID
	if first := history[repo.PhotosStorageWarningTemplateID]; first > 0 {
		if now-first < 48*time.MicroSecondsInOneHour {
			return state, "", nil
		}
		event = repo.PhotosStorageReminderTemplateID
	}
	claimed, err := repo.ClaimStorageNotification(ctx, tx, userID, event)
	if err != nil {
		return state, "", err
	}
	if err := tx.Commit(); err != nil {
		return state, "", err
	}
	if !claimed {
		return state, "", nil
	}
	return state, event, nil
}

func photosStorageUsagePercent(usage, allowance int64) string {
	var tenths, whole, fraction big.Int
	tenths.Mul(big.NewInt(usage), big.NewInt(1000))
	tenths.Quo(&tenths, big.NewInt(allowance))
	whole.QuoRem(&tenths, big.NewInt(10), &fraction)
	return whole.String() + "." + fraction.String()
}
