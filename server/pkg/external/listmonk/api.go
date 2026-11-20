package listmonk

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/ente/stacktrace"
)

type Credentials struct {
	BaseURL  string
	Username string
	Password string
}

const listmonkRequestTimeout = 60 * time.Second

var ErrSubscriberNotFound = errors.New("subscriber not found")

type Subscriber struct {
	Email   string
	ListIDs []int
}

type SubscribersPage struct {
	Results []Subscriber
	Total   int
	Page    int
	PerPage int
}

func GetSubscriberID(endpoint string, username string, password string, subscriberEmail string) (int, error) {
	type SubscriberResponse struct {
		Data struct {
			Results []struct {
				ID int `json:"id"`
			} `json:"results"`
		} `json:"data"`
	}

	// Escape single quotes to prevent SQL-like injection in Listmonk's query syntax
	sanitizedEmail := strings.ReplaceAll(subscriberEmail, "'", "''")
	queryParams := url.Values{}
	queryParams.Set("query", fmt.Sprintf("subscribers.email = '%s'", sanitizedEmail))

	endpointURL, err := url.Parse(endpoint)
	if err != nil {
		return 0, stacktrace.Propagate(err, "")
	}
	endpointURL.RawQuery = queryParams.Encode()

	req, err := http.NewRequest("GET", endpointURL.String(), nil)
	if err != nil {
		return 0, stacktrace.Propagate(err, "")
	}

	req.SetBasicAuth(username, password)

	client := &http.Client{Timeout: listmonkRequestTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return 0, stacktrace.Propagate(err, "")
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, stacktrace.Propagate(err, "")
	}
	if resp.StatusCode != http.StatusOK {
		return 0, stacktrace.Propagate(
			fmt.Errorf("listmonk request failed with status %d: %s", resp.StatusCode, strings.TrimSpace(string(body))),
			"",
		)
	}

	var subscriberResp SubscriberResponse
	if err := json.Unmarshal(body, &subscriberResp); err != nil {
		return 0, stacktrace.Propagate(err, "")
	}

	if len(subscriberResp.Data.Results) == 0 {
		return 0, stacktrace.Propagate(ErrSubscriberNotFound, "")
	}

	id := subscriberResp.Data.Results[0].ID

	return id, nil
}

func ListSubscribers(endpoint string, username string, password string, page int, perPage int) (SubscribersPage, error) {
	type subscriberResponse struct {
		Data struct {
			Results []map[string]json.RawMessage `json:"results"`
			Total   int                          `json:"total"`
			Page    int                          `json:"page"`
			PerPage int                          `json:"per_page"`
		} `json:"data"`
	}

	endpointURL, err := url.Parse(endpoint)
	if err != nil {
		return SubscribersPage{}, stacktrace.Propagate(err, "")
	}

	queryParams := endpointURL.Query()
	queryParams.Set("page", strconv.Itoa(page))
	queryParams.Set("per_page", strconv.Itoa(perPage))
	endpointURL.RawQuery = queryParams.Encode()

	req, err := http.NewRequest("GET", endpointURL.String(), nil)
	if err != nil {
		return SubscribersPage{}, stacktrace.Propagate(err, "")
	}
	req.SetBasicAuth(username, password)

	client := &http.Client{Timeout: listmonkRequestTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return SubscribersPage{}, stacktrace.Propagate(err, "")
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return SubscribersPage{}, stacktrace.Propagate(err, "")
	}
	if resp.StatusCode != http.StatusOK {
		return SubscribersPage{}, stacktrace.Propagate(
			fmt.Errorf("listmonk request failed with status %d: %s", resp.StatusCode, strings.TrimSpace(string(body))),
			"",
		)
	}

	var parsed subscriberResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		return SubscribersPage{}, stacktrace.Propagate(err, "")
	}

	results := make([]Subscriber, 0, len(parsed.Data.Results))
	for _, row := range parsed.Data.Results {
		subscriber, parseErr := parseSubscriber(row)
		if parseErr != nil {
			return SubscribersPage{}, stacktrace.Propagate(parseErr, "")
		}
		results = append(results, subscriber)
	}

	return SubscribersPage{
		Results: results,
		Total:   parsed.Data.Total,
		Page:    parsed.Data.Page,
		PerPage: parsed.Data.PerPage,
	}, nil
}

func parseSubscriber(data map[string]json.RawMessage) (Subscriber, error) {
	emailRaw, ok := data["email"]
	if !ok {
		return Subscriber{}, stacktrace.Propagate(errors.New("missing email in listmonk subscriber payload"), "")
	}
	var email string
	if err := json.Unmarshal(emailRaw, &email); err != nil {
		return Subscriber{}, stacktrace.Propagate(err, "failed to parse listmonk subscriber email")
	}

	var listIDs []int
	if listsRaw, ok := data["lists"]; ok {
		ids, err := decodeListIDs(listsRaw)
		if err != nil {
			return Subscriber{}, stacktrace.Propagate(err, "failed to parse listmonk subscriber lists")
		}
		listIDs = ids
	} else if listIDsRaw, ok := data["list_ids"]; ok {
		ids, err := decodeListIDs(listIDsRaw)
		if err != nil {
			return Subscriber{}, stacktrace.Propagate(err, "failed to parse listmonk subscriber list_ids")
		}
		listIDs = ids
	}

	return Subscriber{
		Email:   email,
		ListIDs: listIDs,
	}, nil
}

func decodeListIDs(raw json.RawMessage) ([]int, error) {
	type listWithID struct {
		ID int `json:"id"`
	}

	if len(raw) == 0 || string(raw) == "null" {
		return []int{}, nil
	}

	var directIntIDs []int
	if err := json.Unmarshal(raw, &directIntIDs); err == nil {
		return directIntIDs, nil
	}

	var objectIDs []listWithID
	if err := json.Unmarshal(raw, &objectIDs); err == nil {
		ids := make([]int, 0, len(objectIDs))
		for _, item := range objectIDs {
			ids = append(ids, item.ID)
		}
		return ids, nil
	}

	var generic []map[string]interface{}
	if err := json.Unmarshal(raw, &generic); err == nil {
		ids := make([]int, 0, len(generic))
		for _, item := range generic {
			value, ok := item["id"]
			if !ok {
				continue
			}
			switch typed := value.(type) {
			case float64:
				ids = append(ids, int(typed))
			case int:
				ids = append(ids, typed)
			case string:
				id, convErr := strconv.Atoi(typed)
				if convErr == nil {
					ids = append(ids, id)
				}
			}
		}
		return ids, nil
	}

	return nil, errors.New("unsupported list ids format")
}

func SendRequest(method string, url string, data interface{}, username string, password string) error {
	jsonData, err := json.Marshal(data)
	if err != nil {
		return stacktrace.Propagate(err, "")
	}

	client := &http.Client{Timeout: listmonkRequestTimeout}
	req, err := http.NewRequest(method, url, bytes.NewBuffer(jsonData))
	if err != nil {
		return stacktrace.Propagate(err, "")
	}

	req.SetBasicAuth(username, password)
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return stacktrace.Propagate(err, "")
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, readErr := io.ReadAll(resp.Body)
		if readErr != nil {
			return stacktrace.Propagate(readErr, "")
		}
		return stacktrace.Propagate(
			fmt.Errorf("listmonk request failed with status %d: %s", resp.StatusCode, strings.TrimSpace(string(body))),
			"",
		)
	}

	return nil
}

type List struct {
	ID        int       `json:"id"`
	CreatedAt time.Time `json:"created_at"`
}

// ListsByQuery is the body of PUT /api/subscribers/query/lists. Subscribers
// are selected from ListIDs by SubscriptionStatus and Query, then Action
// ("add" or "unsubscribe") is applied to them on TargetListIDs.
type ListsByQuery struct {
	Query              string `json:"query,omitempty"`
	ListIDs            []int  `json:"list_ids"`
	SubscriptionStatus string `json:"subscription_status"`
	Action             string `json:"action"`
	TargetListIDs      []int  `json:"target_list_ids"`
	Status             string `json:"status,omitempty"`
}

type Campaign struct {
	Name        string `json:"name"`
	Subject     string `json:"subject"`
	FromEmail   string `json:"from_email"`
	Body        string `json:"body"`
	ContentType string `json:"content_type"`
	TemplateID  int    `json:"template_id"`
	ListIDs     []int  `json:"lists"`
}

func CreateList(c Credentials, name string, tags []string) (int, error) {
	var list List
	err := call(c, http.MethodPost, "/api/lists", map[string]interface{}{
		"name": name, "type": "private", "optin": "single", "tags": tags,
	}, &list)
	return list.ID, err
}

func ListsByTag(c Credentials, tag string) ([]List, error) {
	var page struct {
		Results []List `json:"results"`
	}
	err := call(c, http.MethodGet, "/api/lists?per_page=all&tag="+url.QueryEscape(tag), nil, &page)
	return page.Results, err
}

func DeleteList(c Credentials, id int) error {
	return call(c, http.MethodDelete, "/api/lists/"+strconv.Itoa(id), nil, nil)
}

func ManageListsByQuery(c Credentials, req ListsByQuery) error {
	return call(c, http.MethodPut, "/api/subscribers/query/lists", req, nil)
}

func CreateCampaign(c Credentials, campaign Campaign) (int, error) {
	var created struct {
		ID int `json:"id"`
	}
	err := call(c, http.MethodPost, "/api/campaigns", campaign, &created)
	return created.ID, err
}

func StartCampaign(c Credentials, id int) error {
	return call(c, http.MethodPut, "/api/campaigns/"+strconv.Itoa(id)+"/status", map[string]string{"status": "running"}, nil)
}

// EmailsQuery returns the SQL expression Listmonk expects for matching
// subscribers by email.
func EmailsQuery(emails []string) string {
	quoted := make([]string, len(emails))
	for i, email := range emails {
		quoted[i] = "'" + strings.ReplaceAll(email, "'", "''") + "'"
	}
	return "subscribers.email IN (" + strings.Join(quoted, ",") + ")"
}

// call sends a JSON request and decodes the "data" field of the response
// into out, unless out is nil.
func call(c Credentials, method string, path string, in interface{}, out interface{}) error {
	var body io.Reader
	if in != nil {
		jsonData, err := json.Marshal(in)
		if err != nil {
			return stacktrace.Propagate(err, "")
		}
		body = bytes.NewReader(jsonData)
	}
	req, err := http.NewRequest(method, strings.TrimRight(c.BaseURL, "/")+path, body)
	if err != nil {
		return stacktrace.Propagate(err, "")
	}
	req.SetBasicAuth(c.Username, c.Password)
	req.Header.Set("Content-Type", "application/json")

	resp, err := (&http.Client{Timeout: listmonkRequestTimeout}).Do(req)
	if err != nil {
		return stacktrace.Propagate(err, "")
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return stacktrace.Propagate(err, "")
	}
	if resp.StatusCode != http.StatusOK {
		return stacktrace.Propagate(
			fmt.Errorf("listmonk %s %s failed with status %d: %s", method, path, resp.StatusCode, strings.TrimSpace(string(respBody))),
			"",
		)
	}
	if out == nil {
		return nil
	}
	return stacktrace.Propagate(json.Unmarshal(respBody, &struct {
		Data interface{} `json:"data"`
	}{Data: out}), "")
}
