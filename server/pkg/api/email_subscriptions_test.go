package api

import (
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/internal/testutil"
	"github.com/ente/museum/pkg/repo"
	"github.com/ente/museum/pkg/utils/crypto"
	"github.com/ente/museum/pkg/utils/email"
	"github.com/gin-gonic/gin"
)

func TestEmailUnsubscribe(t *testing.T) {
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	const userID = 1
	const secondUserID = 2
	testutil.InsertUser(t, db, testutil.UserFixture{UserID: userID, Email: "subscriber@example.test", CreationTime: 1})
	testutil.InsertUser(t, db, testutil.UserFixture{UserID: secondUserID, Email: "second-subscriber@example.test", CreationTime: 1})
	_, err := db.Exec(`
		INSERT INTO email_subscriptions VALUES ($1, $3, TRUE), ($2, $3, TRUE)`,
		userID, secondUserID, ente.ProductMailsEmailType)
	if err != nil {
		t.Fatal(err)
	}

	const oldKey = "test-previous-unsubscribe-key-for-email"
	oldLinks, err := email.NewUnsubscribeLinks("https://example.test", []string{oldKey})
	if err != nil {
		t.Fatal(err)
	}
	links, err := email.NewUnsubscribeLinks("https://example.test", []string{"test-new-unsubscribe-key-for-email", oldKey})
	if err != nil {
		t.Fatal(err)
	}
	productLink := oldLinks.URL(userID, ente.ProductMailsEmailType)
	body, err := email.RenderMailBodyWithBase("base_v2.html", "locker_intro.html", map[string]interface{}{
		"UnsubscribeURL": productLink,
	})
	if err != nil || !strings.Contains(body, `href="`+productLink+`" style="color: inherit">Unsubscribe</a>`) {
		t.Fatalf("rendered Locker email is missing its unsubscribe link, err = %v", err)
	}
	secondProductLink := links.URL(secondUserID, ente.ProductMailsEmailType)

	museum := gin.New()
	museum.LoadHTMLGlob("web-templates/*")
	handler := &EmailSubscriptionsHandler{Repo: &repo.EmailSubscriptionRepository{DB: db}, Links: links}
	museum.GET("/email/unsubscribe", handler.Unsubscribe)
	museum.POST("/email/unsubscribe", handler.Unsubscribe)
	request := func(method, link, form, contentType string) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(method, link, strings.NewReader(form))
		req.Header.Set("Content-Type", contentType)
		recorder := httptest.NewRecorder()
		museum.ServeHTTP(recorder, req)
		return recorder
	}
	checkSubscribed := func(userID int64, want bool) {
		t.Helper()
		var got bool
		err := db.QueryRow(`
			SELECT subscribed FROM email_subscriptions WHERE user_id = $1 AND email_type = $2`,
			userID, ente.ProductMailsEmailType).Scan(&got)
		if err != nil || got != want {
			t.Fatalf("Product Mails subscription for %d = %t, err = %v, want %t", userID, got, err, want)
		}
	}

	const formContentType = "application/x-www-form-urlencoded"
	page := request(http.MethodGet, productLink, "", "")
	if page.Code != http.StatusOK || !strings.Contains(page.Body.String(), "Unsubscribe from Product Mails?") {
		t.Fatalf("confirmation page returned %d, body = %s", page.Code, page.Body.String())
	}
	checkSubscribed(userID, true)

	tampered := strings.Replace(productLink, "token=1.", "token=2.", 1)
	if res := request(http.MethodPost, tampered, "List-Unsubscribe=One-Click", formContentType); res.Code != http.StatusBadRequest {
		t.Fatalf("tampered link status = %d, want 400", res.Code)
	}
	newsletterLink := links.URL(userID, ente.EmailType("newsletter"))
	if res := request(http.MethodPost, newsletterLink, "List-Unsubscribe=One-Click", formContentType); res.Code != http.StatusBadRequest {
		t.Fatalf("Newsletter link status = %d, want 400", res.Code)
	}
	checkSubscribed(secondUserID, true)

	subscribed, err := handler.Repo.SubscribedUserIDs(t.Context(), []int64{userID}, ente.ProductMailsEmailType)
	if err != nil || !subscribed[userID] {
		t.Fatalf("Product recipients before opt-out = %v, err = %v", subscribed, err)
	}

	page = request(http.MethodPost, productLink, "confirm=1", formContentType)
	if page.Code != http.StatusOK || !strings.Contains(page.Body.String(), "You will no longer receive Product Mails") {
		t.Fatalf("unsubscribe confirmation returned %d, body = %s", page.Code, page.Body.String())
	}
	checkSubscribed(userID, false)
	checkSubscribed(secondUserID, true)

	users := &repo.UserRepository{DB: db}
	newEmail, err := crypto.Encrypt("new-address@example.test", testutil.SecretEncryptionKey())
	if err != nil {
		t.Fatal(err)
	}
	newHash, err := crypto.GetHash("new-address@example.test", testutil.HashingKey())
	if err != nil {
		t.Fatal(err)
	}
	if err := users.UpdateEmail(userID, newEmail, newHash); err != nil {
		t.Fatal(err)
	}
	subscribed, err = handler.Repo.SubscribedUserIDs(t.Context(), []int64{userID}, ente.ProductMailsEmailType)
	if err != nil || len(subscribed) != 0 {
		t.Fatalf("Product recipients after opt-out and email change = %v, err = %v", subscribed, err)
	}

	var form strings.Builder
	writer := multipart.NewWriter(&form)
	if err := writer.WriteField("List-Unsubscribe", "One-Click"); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if res := request(http.MethodPost, secondProductLink, form.String(), writer.FormDataContentType()); res.Code != http.StatusNoContent {
			t.Fatalf("one-click unsubscribe returned %d, want 204", res.Code)
		}
	}
	checkSubscribed(secondUserID, false)
}
