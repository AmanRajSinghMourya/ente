package email

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/ente/museum/pkg/external/listmonk"
	"github.com/google/uuid"
	log "github.com/sirupsen/logrus"
)

type PromotionalMailer interface {
	PromotionalEnabled() bool
	SubmitPromotionalBatch(listmonk.PromotionalBatch) error
}

func (c *EmailNotificationController) sendPromotionalEmail(templateID, template, subject string, userIDs []int64, dataByUserID map[int64]json.RawMessage) error {
	if len(userIDs) == 0 {
		return nil
	}

	body, err := os.ReadFile(filepath.Join("mail-templates", template))
	if err != nil {
		return err
	}

	recipients := make([]listmonk.PromotionalRecipient, 0, len(userIDs))
	attemptedUserIDs := make([]int64, 0, len(userIDs))
	for _, userID := range userIDs {
		user, err := c.UserRepo.Get(userID)
		if err != nil {
			log.WithField("user_id", userID).WithError(err).Error("Could not fetch promotional email recipient")
			continue
		}
		recipients = append(recipients, listmonk.PromotionalRecipient{Email: user.Email, Data: dataByUserID[userID]})
		attemptedUserIDs = append(attemptedUserIDs, userID)
	}
	if len(recipients) == 0 {
		return nil
	}

	if err := c.NotificationHistoryRepo.SetLastNotificationTimeToNowForUsers(attemptedUserIDs, templateID); err != nil {
		return err
	}
	batch := listmonk.PromotionalBatch{
		ID: uuid.NewString(), EmailType: templateID, Subject: subject, Body: string(body), Recipients: recipients,
	}
	if err := c.PromotionalMailer.SubmitPromotionalBatch(batch); err != nil {
		return fmt.Errorf("submit promotional batch %s: %w", batch.ID, err)
	}
	return nil
}
