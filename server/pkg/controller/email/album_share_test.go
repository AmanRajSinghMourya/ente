package email

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/internal/testutil"
	"github.com/ente/museum/pkg/repo"
	"github.com/ente/museum/pkg/repo/remotestore"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/require"
)

func setupAlbumShareEmailTest(t *testing.T, recipientEmail string) (*EmailNotificationController, int64, int64) {
	t.Helper()
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	senderID := testutil.InsertUser(t, db, testutil.UserFixture{UserID: 1, Email: "sender@example.com", CreationTime: 1})
	recipientID := testutil.InsertUser(t, db, testutil.UserFixture{UserID: 2, Email: recipientEmail, CreationTime: 1})
	remoteStoreRepo := &remotestore.Repository{DB: db}
	require.NoError(t, remoteStoreRepo.InsertOrUpdate(t.Context(), recipientID, string(ente.IsInternalUser), "true"))
	controller := &EmailNotificationController{
		RemoteStoreRepo: remoteStoreRepo,
		UserRepo:        &repo.UserRepository{DB: db, HashingKey: testutil.HashingKey(), SecretEncryptionKey: testutil.SecretEncryptionKey()},
	}
	originalSend := sendAlbumShareTemplatedEmail
	t.Cleanup(func() { sendAlbumShareTemplatedEmail = originalSend })
	return controller, senderID, recipientID
}

func TestAlbumShareEmailRecipientAndCopy(t *testing.T) {
	controller, senderID, recipientID := setupAlbumShareEmailTest(t, "recipient@example.com")
	originalURL := viper.Get("apps.photos")
	t.Cleanup(func() { viper.Set("apps.photos", originalURL) })
	viper.Set("apps.photos", "https://photos.example.com")
	for _, tc := range []struct {
		count   int
		subject string
	}{{1, "An album was shared with you"}, {3, "3 albums were shared with you"}} {
		t.Run(tc.subject, func(t *testing.T) {
			calls := 0
			sendAlbumShareTemplatedEmail = func(to []string, fromName, fromEmail, subject, base, template string, data map[string]interface{}, images []map[string]interface{}) error {
				calls++
				require.Equal(t, []string{"recipient@example.com"}, to)
				require.Equal(t, "Ente", fromName)
				require.Equal(t, "team@ente.com", fromEmail)
				require.Equal(t, tc.subject, subject)
				require.Equal(t, "base.html", base)
				require.Equal(t, "album_shared.html", template)
				require.Equal(t, map[string]interface{}{
					"SenderEmail": "sender@example.com", "AlbumCount": tc.count, "PhotosURL": "https://photos.example.com",
				}, data)
				return nil
			}
			controller.sendAlbumShareEmail(senderID, recipientID, tc.count)
			require.Equal(t, 1, calls)
		})
	}
}

func TestAlbumShareEmailNotifiesEverySharingAction(t *testing.T) {
	controller, senderID, recipientID := setupAlbumShareEmailTest(t, "recipient@example.com")
	var calls atomic.Int32
	sendAlbumShareTemplatedEmail = func([]string, string, string, string, string, string, map[string]interface{}, []map[string]interface{}) error {
		calls.Add(1)
		return nil
	}
	var workers sync.WaitGroup
	for range 8 {
		workers.Add(1)
		go func() {
			defer workers.Done()
			controller.sendAlbumShareEmail(senderID, recipientID, 1)
		}()
	}
	workers.Wait()
	controller.sendAlbumShareEmail(senderID, recipientID, 2)
	require.EqualValues(t, 9, calls.Load())
}

func TestAlbumShareEmailFailureDoesNotSuppressLaterShares(t *testing.T) {
	controller, senderID, recipientID := setupAlbumShareEmailTest(t, "recipient@example.com")
	calls := 0
	sendAlbumShareTemplatedEmail = func([]string, string, string, string, string, string, map[string]interface{}, []map[string]interface{}) error {
		calls++
		if calls == 1 {
			return errors.New("SMTP unavailable")
		}
		return nil
	}
	for range 3 {
		controller.sendAlbumShareEmail(senderID, recipientID, 1)
	}
	require.Equal(t, 3, calls)
}

func TestAlbumShareEmailOnlyInternalRecipients(t *testing.T) {
	for _, tc := range []struct {
		email     string
		flag      string
		wantCalls int
	}{
		{"recipient@example.com", "true", 1},
		{"recipient@example.com", "false", 0},
		{"recipient@example.com", "", 0},
		{"recipient@ente.com", "", 0},
		{"recipient@ente.io", "false", 0},
		{"recipient@ente.com", "true", 1},
	} {
		t.Run(tc.email+"/"+tc.flag, func(t *testing.T) {
			controller, senderID, recipientID := setupAlbumShareEmailTest(t, tc.email)
			remoteStoreRepo := &remotestore.Repository{DB: controller.UserRepo.DB}
			require.NoError(t, remoteStoreRepo.InsertOrUpdate(t.Context(), senderID, string(ente.IsInternalUser), "true"))
			if tc.flag == "" {
				require.NoError(t, remoteStoreRepo.RemoveKey(t.Context(), recipientID, string(ente.IsInternalUser)))
			} else {
				require.NoError(t, remoteStoreRepo.InsertOrUpdate(t.Context(), recipientID, string(ente.IsInternalUser), tc.flag))
			}
			calls := 0
			sendAlbumShareTemplatedEmail = func([]string, string, string, string, string, string, map[string]interface{}, []map[string]interface{}) error {
				calls++
				return nil
			}
			controller.sendAlbumShareEmail(senderID, recipientID, 1)
			require.Equal(t, tc.wantCalls, calls)
		})
	}
}
