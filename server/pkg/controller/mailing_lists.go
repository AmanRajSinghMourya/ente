package controller

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
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
	listmonkListIDs        []int
	listmonkCredentials    listmonk.Credentials
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

func (c *MailingListsController) PrepareProductMailBatch(name string, emails []string) (int, error) {
	var batches struct {
		Results []struct {
			ID        int       `json:"id"`
			CreatedAt time.Time `json:"created_at"`
		} `json:"results"`
	}
	err := c.listmonkRequest("GET", "/api/lists?per_page=all&tag="+productMailsBatchTag, nil, &batches)
	if err != nil {
		return 0, stacktrace.Propagate(err, "")
	}
	for _, batch := range batches.Results {
		err = c.listmonkRequest("PUT", "/api/subscribers/query/lists", map[string]interface{}{
			"list_ids":            []int{batch.ID},
			"subscription_status": "unsubscribed",
			"action":              "unsubscribe",
			"target_list_ids":     []int{c.productMailsListID},
		}, nil)
		if err != nil {
			return 0, stacktrace.Propagate(err, "")
		}
		if time.Since(batch.CreatedAt) > productMailsBatchRetention {
			err = c.listmonkRequest("DELETE", "/api/lists/"+strconv.Itoa(batch.ID), nil, nil)
			if err != nil {
				return 0, stacktrace.Propagate(err, "")
			}
		}
	}

	var batch struct {
		ID int `json:"id"`
	}
	err = c.listmonkRequest("POST", "/api/lists", map[string]interface{}{
		"name": name, "type": "private", "optin": "single", "tags": []string{productMailsBatchTag},
	}, &batch)
	if err != nil {
		return 0, stacktrace.Propagate(err, "")
	}
	quoted := make([]string, len(emails))
	for i, email := range emails {
		quoted[i] = "'" + strings.ReplaceAll(email, "'", "''") + "'"
	}
	for _, status := range []string{"unconfirmed", "confirmed"} {
		err = c.listmonkRequest("PUT", "/api/subscribers/query/lists", map[string]interface{}{
			"query":               "subscribers.email IN (" + strings.Join(quoted, ",") + ")",
			"list_ids":            []int{c.productMailsListID},
			"subscription_status": status,
			"action":              "add",
			"target_list_ids":     []int{batch.ID},
			"status":              "unconfirmed",
		}, nil)
		if err != nil {
			return 0, stacktrace.Propagate(err, "")
		}
	}
	return batch.ID, nil
}

func (c *MailingListsController) StartProductMailCampaign(batchID int, name string, subject string, body string) error {
	var campaign struct {
		ID int `json:"id"`
	}
	err := c.listmonkRequest("POST", "/api/campaigns", map[string]interface{}{
		"name":         name,
		"subject":      subject,
		"from_email":   productMailsFromEmail,
		"body":         body,
		"content_type": "html",
		"template_id":  c.productMailsTemplateID,
		"lists":        []int{batchID},
	}, &campaign)
	if err != nil {
		return stacktrace.Propagate(err, "")
	}
	return stacktrace.Propagate(c.listmonkRequest("PUT", "/api/campaigns/"+strconv.Itoa(campaign.ID)+"/status",
		map[string]string{"status": "running"}, nil), "")
}

func (c *MailingListsController) listmonkRequest(method string, path string, data interface{}, out interface{}) error {
	return listmonk.Request(method, c.listmonkCredentials.BaseURL+path, data, out,
		c.listmonkCredentials.Username, c.listmonkCredentials.Password)
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
