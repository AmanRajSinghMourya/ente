package email

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/ente/museum/ente"
	emailUtil "github.com/ente/museum/pkg/utils/email"
	log "github.com/sirupsen/logrus"
)

var sendAlbumShareTemplatedEmail = emailUtil.SendTemplatedEmailV2

func (c *EmailNotificationController) QueueAlbumShareEmail(senderID, recipientID int64, albumCount int) {
	go c.sendAlbumShareEmail(senderID, recipientID, albumCount)
}

func (c *EmailNotificationController) sendAlbumShareEmail(senderID, recipientID int64, albumCount int) {
	value, err := c.RemoteStoreRepo.GetValue(context.Background(), recipientID, string(ente.IsInternalUser))
	if err != nil {
		if !errors.Is(err, sql.ErrNoRows) {
			log.WithError(err).Error("Could not read album share recipient internal user flag")
		}
		return
	}
	if value != "true" {
		return
	}
	sender, err := c.UserRepo.Get(senderID)
	if err != nil {
		log.WithError(err).Error("Could not find album share sender")
		return
	}
	recipient, err := c.UserRepo.Get(recipientID)
	if err != nil {
		log.WithError(err).Error("Could not find album share recipient")
		return
	}
	subject := "An album was shared with you"
	if albumCount > 1 {
		subject = fmt.Sprintf("%d albums were shared with you", albumCount)
	}
	err = sendAlbumShareTemplatedEmail(
		[]string{recipient.Email}, "Ente", "team@ente.com", subject,
		"base.html", "album_shared.html", map[string]interface{}{
			"SenderEmail": sender.Email,
			"AlbumCount":  albumCount,
		}, nil)
	if err != nil {
		log.WithError(err).Error("Could not send album share email")
		return
	}
}
