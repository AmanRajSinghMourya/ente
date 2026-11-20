package controller

import (
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/ente/museum/pkg/controller/discord"
	"github.com/ente/museum/pkg/external/listmonk"
	"github.com/ente/stacktrace"
	log "github.com/sirupsen/logrus"
	"github.com/spf13/viper"
)

const (
	productMailsFromEmail      = "Ente <team@ente.com>"
	productMailsBatchTag       = "product-mails-batch"
	productMailsBatchRetention = 30 * 24 * time.Hour
)

type MailingListsController struct {
	listmonkListIDs     []int
	listmonkCredentials listmonk.Credentials
	// The list that records who accepts product mails, and the campaign
	// template that wraps them.
	productMailsListID     int
	productMailsTemplateID int
	discordController      *discord.DiscordController
}

func NewMailingListsController(discordController *discord.DiscordController) *MailingListsController {
	listmonkCredentials := listmonk.Credentials{
		BaseURL:  viper.GetString("listmonk.server-url"),
		Username: viper.GetString("listmonk.username"),
		Password: viper.GetString("listmonk.password"),
	}

	listmonkListIDs := viper.GetIntSlice("listmonk.list-ids")

	return &MailingListsController{
		listmonkCredentials:    listmonkCredentials,
		listmonkListIDs:        listmonkListIDs,
		productMailsListID:     viper.GetInt("listmonk.product-mails.list-id"),
		productMailsTemplateID: viper.GetInt("listmonk.product-mails.template-id"),
		discordController:      discordController,
	}
}

func (c *MailingListsController) ProductMailsEnabled() bool {
	return !c.shouldSkipListmonk() && c.productMailsListID != 0 && c.productMailsTemplateID != 0
}

// PrepareProductMailBatch creates a list holding those of the given emails
// that still accept product mails, and returns its ID.
//
// A campaign's unsubscribe link only unsubscribes from the campaign's own
// list, so unsubscribes from earlier batches are first copied to the
// product mails list.
func (c *MailingListsController) PrepareProductMailBatch(name string, emails []string) (int, error) {
	batches, err := listmonk.ListsByTag(c.listmonkCredentials, productMailsBatchTag)
	if err != nil {
		return 0, stacktrace.Propagate(err, "")
	}
	for _, batch := range batches {
		err = listmonk.ManageListsByQuery(c.listmonkCredentials, listmonk.ListsByQuery{
			ListIDs:            []int{batch.ID},
			SubscriptionStatus: "unsubscribed",
			Action:             "unsubscribe",
			TargetListIDs:      []int{c.productMailsListID},
		})
		if err != nil {
			return 0, stacktrace.Propagate(err, "")
		}
		if time.Since(batch.CreatedAt) > productMailsBatchRetention {
			if err = listmonk.DeleteList(c.listmonkCredentials, batch.ID); err != nil {
				return 0, stacktrace.Propagate(err, "")
			}
		}
	}

	batchID, err := listmonk.CreateList(c.listmonkCredentials, name, []string{productMailsBatchTag})
	if err != nil {
		return 0, stacktrace.Propagate(err, "")
	}
	for _, status := range []string{"unconfirmed", "confirmed"} {
		err = listmonk.ManageListsByQuery(c.listmonkCredentials, listmonk.ListsByQuery{
			Query:              listmonk.EmailsQuery(emails),
			ListIDs:            []int{c.productMailsListID},
			SubscriptionStatus: status,
			Action:             "add",
			TargetListIDs:      []int{batchID},
			Status:             "unconfirmed",
		})
		if err != nil {
			return 0, stacktrace.Propagate(err, "")
		}
	}
	return batchID, nil
}

func (c *MailingListsController) StartProductMailCampaign(batchID int, name string, subject string, body string) error {
	campaignID, err := listmonk.CreateCampaign(c.listmonkCredentials, listmonk.Campaign{
		Name:        name,
		Subject:     subject,
		FromEmail:   productMailsFromEmail,
		Body:        body,
		ContentType: "html",
		TemplateID:  c.productMailsTemplateID,
		ListIDs:     []int{batchID},
	})
	if err != nil {
		return stacktrace.Propagate(err, "")
	}
	return stacktrace.Propagate(listmonk.StartCampaign(c.listmonkCredentials, campaignID), "")
}

func (c *MailingListsController) Subscribe(email string) error {
	if !(c.shouldSkipListmonk()) {
		err := c.listmonkSubscribe(email)
		if err != nil {
			return stacktrace.Propagate(err, "")
		}
	}
	return nil
}

func (c *MailingListsController) Unsubscribe(email string) error {
	if !(c.shouldSkipListmonk()) {
		err := c.listmonkUnsubscribe(email)
		if err != nil {
			return stacktrace.Propagate(err, "")
		}
	}
	return nil
}

func (c *MailingListsController) shouldSkipListmonk() bool {
	if c.listmonkCredentials.BaseURL == "" || c.listmonkCredentials.Username == "" ||
		c.listmonkCredentials.Password == "" || len(c.listmonkListIDs) == 0 {
		return true
	}
	return false
}

func (c *MailingListsController) listmonkSubscribe(email string) error {
	data := map[string]interface{}{
		"email": email,
		"lists": c.listmonkListIDs,
	}
	err := listmonk.SendRequest("POST", c.listmonkCredentials.BaseURL+"/api/subscribers", data,
		c.listmonkCredentials.Username, c.listmonkCredentials.Password)
	if err != nil {
		log.Errorf("Listmonk subscribe failed '%s': %s", email, err)
		c.notifyListmonkFailure("Listmonk subscribe failed", err)
	}
	return err
}

func (c *MailingListsController) listmonkUnsubscribe(email string) error {
	// Listmonk deletion needs a subscriber ID, so look it up by email first.
	id, err := listmonk.GetSubscriberID(c.listmonkCredentials.BaseURL+"/api/subscribers",
		c.listmonkCredentials.Username, c.listmonkCredentials.Password, email)
	if err != nil {
		log.Errorf("Listmonk - Unsub failed for '%s': %s", email, err)
		if !errors.Is(err, listmonk.ErrSubscriberNotFound) {
			c.notifyListmonkFailure("Listmonk - Unsub failed", err)
		}
		return stacktrace.Propagate(err, "")
	}

	err = listmonk.SendRequest("DELETE", c.listmonkCredentials.BaseURL+"/api/subscribers/"+strconv.Itoa(id),
		map[string]interface{}{}, c.listmonkCredentials.Username, c.listmonkCredentials.Password)
	if err != nil {
		log.Errorf("Listmonk - Unsub failed to delete '%s': %s", email, err)
		c.notifyListmonkFailure("Listmonk - Unsub failed to delete", err)
	}
	return err
}

func (c *MailingListsController) notifyListmonkFailure(message string, err error) {
	c.discordController.Notify(fmt.Sprintf("%s: %v", message, err))
}
