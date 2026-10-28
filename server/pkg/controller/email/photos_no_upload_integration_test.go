package email

import (
	"database/sql"
	"errors"
	"fmt"
	"testing"

	"github.com/ente/museum/internal/testutil"
	"github.com/ente/museum/pkg/repo"
	timeutil "github.com/ente/museum/pkg/utils/time"
)

func TestSendPhotosNoUploadMailsSendsOnceIntegration(t *testing.T) {
	ctrl, db := setupPhotosNoUploadIntegrationTest(t)
	for userID := int64(1); userID <= 2; userID++ {
		insertPhotosNoUploadIntegrationUser(t, db, userID, timeutil.MicrosecondsBeforeDays(3)+userID)
	}
	insertPhotosNoUploadIntegrationUser(t, db, 3, timeutil.MicrosecondsBeforeDays(1))

	sent := stubPhotosNoUploadEmail(t, db, nil)
	ctrl.SendPhotosNoUploadMails()
	if want := []string{"photos-no-upload-1@example.com", "photos-no-upload-2@example.com"}; fmt.Sprint(*sent) != fmt.Sprint(want) {
		t.Fatalf("sent = %v, want %v", *sent, want)
	}

	ctrl.SendPhotosNoUploadMails()
	if len(*sent) != 2 {
		t.Fatalf("sent %d emails after a second run, want 2", len(*sent))
	}
}

func TestSendPhotosNoUploadMailsKeepsRowWhenSendFailsIntegration(t *testing.T) {
	ctrl, db := setupPhotosNoUploadIntegrationTest(t)
	insertPhotosNoUploadIntegrationUser(t, db, 1, timeutil.MicrosecondsBeforeDays(3))

	sent := stubPhotosNoUploadEmail(t, db, errors.New("smtp unavailable"))
	ctrl.SendPhotosNoUploadMails()
	ctrl.SendPhotosNoUploadMails()

	if len(*sent) != 1 {
		t.Fatalf("send attempts = %d, want 1", len(*sent))
	}
	assertStorageWarningNotificationCount(t, db, 1, repo.PhotosNoUploadTemplateID, 1)
}

func setupPhotosNoUploadIntegrationTest(t *testing.T) (*EmailNotificationController, *sql.DB) {
	t.Helper()
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() {
		testutil.ResetTables(t, db)
	})
	originalCutoff := photosNoUploadCutoff
	photosNoUploadCutoff = timeutil.MicrosecondsBeforeDays(10)
	t.Cleanup(func() {
		photosNoUploadCutoff = originalCutoff
	})
	return newStorageWarningIntegrationController(db), db
}

func stubPhotosNoUploadEmail(t *testing.T, db *sql.DB, sendErr error) *[]string {
	t.Helper()
	sent := &[]string{}
	original := sendPhotosNoUploadEmail
	sendPhotosNoUploadEmail = func(to []string, fromName string, fromEmail string, subject string, baseTemplate string, templateName string, templateData map[string]interface{}, inlineImages []map[string]interface{}) error {
		var userID int64
		if _, err := fmt.Sscanf(to[0], "photos-no-upload-%d@example.com", &userID); err != nil {
			t.Fatalf("unexpected recipient %q: %v", to[0], err)
		}
		assertStorageWarningNotificationCount(t, db, userID, repo.PhotosNoUploadTemplateID, 1)
		*sent = append(*sent, to[0])
		return sendErr
	}
	t.Cleanup(func() {
		sendPhotosNoUploadEmail = original
	})
	return sent
}

func insertPhotosNoUploadIntegrationUser(t *testing.T, db *sql.DB, userID int64, creationTime int64) {
	t.Helper()
	testutil.InsertUser(t, db, testutil.UserFixture{
		UserID:       userID,
		Email:        fmt.Sprintf("photos-no-upload-%d@example.com", userID),
		CreationTime: creationTime,
	})
	testutil.InsertUsageWithFileCounts(t, db, userID, 0)
	testutil.InsertToken(t, db, userID, "photos", creationTime)
}
