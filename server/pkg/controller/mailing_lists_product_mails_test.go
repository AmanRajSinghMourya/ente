package controller

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/ente/museum/pkg/external/listmonk"
)

func TestPrepareProductMailBatchCarriesOverUnsubscribesBeforeFiltering(t *testing.T) {
	const productMailsListID, recentBatchID, expiredBatchID, newBatchID = 7, 20, 21, 22
	var calls []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		switch r.Method + " " + r.URL.Path {
		case "GET /api/lists":
			if r.URL.Query().Get("tag") != productMailsBatchTag {
				t.Errorf("listed lists with tag %q", r.URL.Query().Get("tag"))
			}
			fmt.Fprintf(w, `{"data":{"results":[{"id":%d,"created_at":%q},{"id":%d,"created_at":%q}]}}`,
				recentBatchID, time.Now().Add(-24*time.Hour).Format(time.RFC3339),
				expiredBatchID, time.Now().Add(-31*24*time.Hour).Format(time.RFC3339))
		case "PUT /api/subscribers/query/lists":
			var req struct {
				Query              string `json:"query"`
				ListIDs            []int  `json:"list_ids"`
				SubscriptionStatus string `json:"subscription_status"`
				Action             string `json:"action"`
				TargetListIDs      []int  `json:"target_list_ids"`
			}
			if err := json.Unmarshal(body, &req); err != nil {
				t.Error(err)
			}
			calls = append(calls, fmt.Sprintf("%s %s from %v to %v", req.Action, req.SubscriptionStatus, req.ListIDs, req.TargetListIDs))
			if req.Action == "add" && req.Query != `subscribers.email IN ('a@example.com','o''b@example.com')` {
				t.Errorf("query = %s", req.Query)
			}
			fmt.Fprint(w, `{"data":true}`)
		case "POST /api/lists":
			if !strings.Contains(string(body), productMailsBatchTag) {
				t.Errorf("batch list created without tag: %s", body)
			}
			calls = append(calls, "create")
			fmt.Fprintf(w, `{"data":{"id":%d}}`, newBatchID)
		case fmt.Sprintf("DELETE /api/lists/%d", expiredBatchID):
			calls = append(calls, "delete expired")
			fmt.Fprint(w, `{"data":true}`)
		default:
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	c := &MailingListsController{
		listmonkCredentials: listmonk.Credentials{BaseURL: server.URL, Username: "user", Password: "pass"},
		productMailsListID:  productMailsListID,
	}

	batchID, err := c.PrepareProductMailBatch("Locker intro", []string{"a@example.com", "o'b@example.com"})
	if err != nil {
		t.Fatal(err)
	}
	if batchID != newBatchID {
		t.Fatalf("batch = %d, want %d", batchID, newBatchID)
	}
	want := []string{
		"unsubscribe unsubscribed from [20] to [7]",
		"unsubscribe unsubscribed from [21] to [7]",
		"delete expired",
		"create",
		"add unconfirmed from [7] to [22]",
		"add confirmed from [7] to [22]",
	}
	if !slices.Equal(calls, want) {
		t.Fatalf("calls =\n%s\nwant\n%s", strings.Join(calls, "\n"), strings.Join(want, "\n"))
	}
}

func TestPrepareProductMailBatchStopsWhenUnsubscribesCannotBeCarriedOver(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method + " " + r.URL.Path {
		case "GET /api/lists":
			fmt.Fprintf(w, `{"data":{"results":[{"id":20,"created_at":%q}]}}`, time.Now().Format(time.RFC3339))
		case "PUT /api/subscribers/query/lists":
			w.WriteHeader(http.StatusInternalServerError)
		default:
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	c := &MailingListsController{
		listmonkCredentials: listmonk.Credentials{BaseURL: server.URL, Username: "user", Password: "pass"},
		productMailsListID:  7,
	}

	if _, err := c.PrepareProductMailBatch("Locker intro", []string{"a@example.com"}); err == nil {
		t.Fatal("recipients were prepared without carrying over unsubscribes")
	}
}
