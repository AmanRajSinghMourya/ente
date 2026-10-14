package storagebonus_test

import (
	"context"
	"encoding/base64"
	"image/png"
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
	entity "github.com/ente/museum/ente/storagebonus"
	"github.com/ente/museum/internal/testutil"
	"github.com/ente/museum/pkg/api"
	"github.com/ente/museum/pkg/controller/email"
	"github.com/ente/museum/pkg/controller/lock"
	"github.com/ente/museum/pkg/controller/storagebonus"
	"github.com/ente/museum/pkg/repo"
	bonusRepo "github.com/ente/museum/pkg/repo/storagebonus"
	"github.com/gin-gonic/gin"
	logtest "github.com/sirupsen/logrus/hooks/test"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/require"
)

func TestReferralEmails(t *testing.T) {
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	for id, address := range map[int64]string{101: "friend@example.com", 102: "referrer@example.com", 103: "other@example.com"} {
		testutil.InsertUser(t, db, testutil.UserFixture{UserID: id, Email: address, CreationTime: 1})
	}
	users := &repo.UserRepository{DB: db, SecretEncryptionKey: testutil.SecretEncryptionKey(), HashingKey: testutil.HashingKey()}
	bonuses := bonusRepo.NewRepository(db)
	require.NoError(t, bonuses.InsertCode(t.Context(), 102, "REFER1"))
	require.NoError(t, bonuses.InsertCode(t.Context(), 103, "REFER2"))
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
	messages, stopSMTP := referralSMTP(t)

	require.Equal(t, http.StatusOK, claim("REFER1"))
	assertReferralMail(t, messages, "friend@example.com", "Your 10 GB referral bonus is here!", "Your referral code was applied, and 10 GB of bonus storage has been credited to your account.", "header-image")
	var count int
	var storage int64
	require.NoError(t, db.QueryRow("SELECT COUNT(*), SUM(storage) FROM storage_bonus WHERE user_id = 101 AND type = 'SIGN_UP'").Scan(&count, &storage))
	require.Equal(t, 1, count)
	require.Equal(t, int64(10<<30), storage)

	// Neither a retry, a second code, nor an invalid code sends another email.
	require.Equal(t, http.StatusConflict, claim("REFER1"))
	require.Equal(t, http.StatusConflict, claim("REFER2"))
	require.Equal(t, http.StatusNotFound, claim("INVALID"))
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
	assertReferralMail(t, messages, "referrer@example.com", "You've earned 10 GB on Ente! 🎁", "One of the customers you referred has upgraded to a paid plan, and as a thank you, we have credited 10 GB to your account.", "header-image")
	controller.PaymentUpgradeOrDowngradeCron()
	require.Equal(t, []int64{102}, push.recipients)
	select {
	case message := <-messages:
		t.Fatalf("unexpected repeat referral email: %s", message)
	default:
	}

	// Email delivery failure must not turn a committed bonus into an API error.
	stopSMTP()
	hook := logtest.NewGlobal()
	_, err := db.Exec("DELETE FROM storage_bonus WHERE user_id = 101; DELETE FROM referral_tracking WHERE invitee_id = 101")
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, claim("REFER1"))
	require.NoError(t, db.QueryRow("SELECT COUNT(*) FROM storage_bonus WHERE user_id = 101 AND type = 'SIGN_UP'").Scan(&count))
	require.Equal(t, 1, count)
	require.Equal(t, http.StatusConflict, claim("REFER1"))
	require.Eventually(t, func() bool {
		for _, entry := range hook.AllEntries() {
			if entry.Message == "Error sending referral code applied email" {
				return true
			}
		}
		return false
	}, 3*time.Second, 10*time.Millisecond)
}

func assertReferralMail(t *testing.T, messages <-chan string, recipient, subject, body string, inlineImages ...string) {
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
	if len(inlineImages) > 0 {
		if recipient == "friend@example.com" {
			require.Contains(t, string(content), "Congratulations! 🎉")
		} else {
			require.Contains(t, string(content), ">Congratulations!</h1>")
			require.Contains(t, string(content), "Thank you for spreading the word!")
		}
		require.NotContains(t, string(content), ">Hi,")
		require.NotContains(t, string(content), "assets/")
		require.Contains(t, string(content), "https://email-assets.ente.com/ente-2026-green.png")
	}
	var imageIDs []string
	for {
		part, err := parts.NextRawPart()
		if err == io.EOF {
			break
		}
		require.NoError(t, err)
		require.Equal(t, "image/png", part.Header.Get("Content-Type"))
		id := strings.Trim(part.Header.Get("Content-ID"), "<>")
		imageIDs = append(imageIDs, id)
		require.Contains(t, string(content), "cid:"+id)
		config, err := png.DecodeConfig(base64.NewDecoder(base64.StdEncoding, part))
		require.NoError(t, err)
		require.Positive(t, config.Width)
		require.Positive(t, config.Height)
	}
	require.ElementsMatch(t, inlineImages, imageIDs)
}

func referralSMTP(t *testing.T) (<-chan string, func()) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)
	stop := func() { _ = listener.Close() }
	t.Cleanup(stop)
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
	return messages, stop
}

type referralPushRecorder struct{ recipients []int64 }

func (p *referralPushRecorder) NotifyReferral(_ context.Context, recipient int64) {
	p.recipients = append(p.recipients, recipient)
}

func TestReferralFamilyOwnership(t *testing.T) {
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	admin := int64(201)
	for _, user := range []testutil.UserFixture{
		{UserID: admin, CreationTime: 1, Email: "admin@example.com", FamilyAdminID: &admin},
		{UserID: 202, CreationTime: 1, Email: "member@example.com", FamilyAdminID: &admin},
		{UserID: 203, CreationTime: 1, Email: "friend@example.com"},
	} {
		testutil.InsertUser(t, db, user)
	}
	bonuses := bonusRepo.NewRepository(db)
	require.NoError(t, bonuses.InsertCode(t.Context(), admin, "ADMIN1"))
	require.NoError(t, bonuses.InsertCode(t.Context(), 202, "MEMBER1"))
	controller := &storagebonus.Controller{StorageBonus: bonuses, UserRepo: &repo.UserRepository{
		DB: db, SecretEncryptionKey: testutil.SecretEncryptionKey(), HashingKey: testutil.HashingKey(),
	}}
	ctx, _ := gin.CreateTestContext(httptest.NewRecorder())
	ctx.Request = httptest.NewRequest(http.MethodGet, "/", nil)
	ctx.Request.Header.Set("X-Auth-User-ID", "202")
	view, err := controller.GetUserReferralView(ctx)
	require.NoError(t, err)
	require.Equal(t, "ADMIN1", *view.Code)
	require.True(t, view.IsFamilyMember)
	require.False(t, view.EnableApplyCode)
	require.ErrorIs(t, controller.ApplyReferralCode(ctx, "ADMIN1"), entity.CanNotApplyCodeErr)

	// An old personal code still credits its original owner after joining a family.
	require.NoError(t, bonuses.TrackReferralAndInviteeBonus(t.Context(), 203, 202, entity.TenGbOnUpgrade))
	require.NoError(t, bonuses.TrackUpgradeAndInvitorBonus(t.Context(), 203, 202, entity.TenGbOnUpgrade))
	var owner int64
	require.NoError(t, db.QueryRow("SELECT user_id FROM storage_bonus WHERE type = 'REFERRAL'").Scan(&owner))
	require.Equal(t, int64(202), owner)
	view, err = controller.GetUserReferralView(ctx)
	require.NoError(t, err)
	require.Zero(t, view.ClaimedStorage)
}
