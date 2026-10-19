package storagebonus_test

import (
	"context"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net"
	"net/http"
	"net/http/httptest"
	"net/mail"
	"net/textproto"
	"strings"
	"testing"
	"time"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/internal/testutil"
	"github.com/ente/museum/pkg/api"
	"github.com/ente/museum/pkg/controller/email"
	"github.com/ente/museum/pkg/controller/lock"
	"github.com/ente/museum/pkg/controller/storagebonus"
	"github.com/ente/museum/pkg/repo"
	bonusRepo "github.com/ente/museum/pkg/repo/storagebonus"
	"github.com/gin-gonic/gin"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/require"
)

func TestReferralEmails(t *testing.T) {
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	for id, address := range map[int64]string{101: "friend@example.com", 102: "referrer@example.com"} {
		testutil.InsertUser(t, db, testutil.UserFixture{UserID: id, Email: address, CreationTime: 1})
	}
	users := &repo.UserRepository{DB: db, SecretEncryptionKey: testutil.SecretEncryptionKey(), HashingKey: testutil.HashingKey()}
	bonuses := bonusRepo.NewRepository(db)
	require.NoError(t, bonuses.InsertCode(t.Context(), 102, "REFER1"))
	push := &referralPushRecorder{}
	controller := &storagebonus.Controller{
		PushCtrl: push,
		UserRepo: users, StorageBonus: bonuses,
		EmailNotificationController: &email.EmailNotificationController{UserRepo: users},
		LockController:              &lock.LockController{TaskLockingRepo: &repo.TaskLockRepository{DB: db}, HostName: "referral-test"},
	}
	handler := api.StorageBonusHandler{Controller: controller}
	router := gin.New()
	router.POST("/referral", handler.ClaimReferral)
	claim := func(code string) int {
		request := httptest.NewRequest(http.MethodPost, "/referral?code="+code, nil)
		request.Header.Set("X-Auth-User-ID", "101")
		response := httptest.NewRecorder()
		router.ServeHTTP(response, request)
		return response.Code
	}
	messages := referralSMTP(t)

	require.Equal(t, http.StatusOK, claim("REFER1"))
	assertReferralMail(t, messages, "friend@example.com", "Your 10 GB referral bonus is here!", "Your referral code was applied, and 10 GB of bonus storage has been credited to your account.")
	var count int
	var storage int64
	require.NoError(t, db.QueryRow("SELECT COUNT(*), SUM(storage) FROM storage_bonus WHERE user_id = 101 AND type = 'SIGN_UP'").Scan(&count, &storage))
	require.Equal(t, 1, count)
	require.Equal(t, int64(10<<30), storage)

	// Retrying the claim must not send another email.
	require.Equal(t, http.StatusConflict, claim("REFER1"))
	controller.PaymentUpgradeOrDowngradeCron()
	select {
	case message := <-messages:
		t.Fatalf("unexpected email before the friend upgrades: %s", message)
	default:
	}

	require.Empty(t, push.recipients)

	// The referrer's existing email is sent only after the friend becomes paid.
	testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{
		UserID: 101, Storage: 50 << 30, ProductID: "photos_yearly", PaymentProvider: ente.Stripe,
		ExpiryTime: time.Now().Add(time.Hour).UnixMicro(),
	})
	controller.PaymentUpgradeOrDowngradeCron()
	assertReferralMail(t, messages, "referrer@example.com", "You've earned 10 GB on Ente! 🎁", "One of the customers you referred has upgraded to a paid plan, and as a thank you, we have credited 10 GB to your account.")
	controller.PaymentUpgradeOrDowngradeCron()
	require.Equal(t, []int64{102}, push.recipients)
	select {
	case message := <-messages:
		t.Fatalf("unexpected repeat referral email: %s", message)
	default:
	}

}

func assertReferralMail(t *testing.T, messages <-chan string, recipient, subject, body string) {
	t.Helper()
	var raw string
	select {
	case raw = <-messages:
	case <-time.After(3 * time.Second):
		t.Fatal("expected referral email was not sent")
	}
	message, err := mail.ReadMessage(strings.NewReader(raw))
	require.NoError(t, err)
	require.Equal(t, recipient, message.Header.Get("To"))
	decodedSubject, err := new(mime.WordDecoder).DecodeHeader(message.Header.Get("Subject"))
	require.NoError(t, err)
	require.Equal(t, subject, decodedSubject)
	_, params, err := mime.ParseMediaType(message.Header.Get("Content-Type"))
	require.NoError(t, err)
	parts := multipart.NewReader(message.Body, params["boundary"])
	part, err := parts.NextRawPart()
	require.NoError(t, err)
	content, err := io.ReadAll(quotedprintable.NewReader(part))
	require.NoError(t, err)
	require.Contains(t, string(content), body)
	require.Contains(t, string(content), "cid:header-image")
	part, err = parts.NextRawPart()
	require.NoError(t, err)
	require.Equal(t, "<header-image>", part.Header.Get("Content-ID"))
	require.Equal(t, "image/png", part.Header.Get("Content-Type"))
}

func referralSMTP(t *testing.T) <-chan string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)
	t.Cleanup(func() { _ = listener.Close() })
	host, port, err := net.SplitHostPort(listener.Addr().String())
	require.NoError(t, err)
	for key, value := range map[string]string{"smtp.host": host, "smtp.port": port, "smtp.username": "", "smtp.password": "", "smtp.encryption": ""} {
		previous := viper.Get(key)
		viper.Set(key, value)
		t.Cleanup(func() { viper.Set(key, previous) })
	}
	messages := make(chan string, 10)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			func() {
				defer conn.Close()
				_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
				client := textproto.NewConn(conn)
				_ = client.PrintfLine("220 localhost")
				var message string
				for {
					line, err := client.ReadLine()
					if err != nil {
						return
					}
					switch {
					case line == "DATA":
						_ = client.PrintfLine("354 Send message")
						data, err := client.ReadDotBytes()
						if err != nil {
							return
						}
						message = string(data)
						_ = client.PrintfLine("250 Accepted")
					case line == "QUIT":
						_ = client.PrintfLine("221 Bye")
						messages <- message
						return
					default:
						_ = client.PrintfLine("250 OK")
					}
				}
			}()
		}
	}()
	return messages
}

type referralPushRecorder struct{ recipients []int64 }

func (p *referralPushRecorder) NotifyReferral(_ context.Context, recipient int64) {
	p.recipients = append(p.recipients, recipient)
}
