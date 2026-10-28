package repo

import (
	"context"
	"database/sql"
	"fmt"
	"slices"
	"testing"

	"github.com/ente/museum/internal/testutil"
)

func TestGetPhotosNoUploadCandidates(t *testing.T) {
	db := getStorageWarningRepoTestDB(t)
	repo := &NotificationHistoryRepository{DB: db}
	const cutoff, createdBefore = int64(1000), int64(2000)

	insertPhotosNoUploadTestUser(t, db, 1, cutoff, 0, "photos")
	insertPhotosNoUploadTestUser(t, db, 2, 1500, 0, "photos")
	insertPhotosNoUploadTestUser(t, db, 3, createdBefore, 0, "photos")

	insertPhotosNoUploadTestUser(t, db, 4, cutoff-1, 0, "photos")

	insertPhotosNoUploadTestUser(t, db, 5, createdBefore+1, 0, "photos")

	insertPhotosNoUploadTestUser(t, db, 6, 1500, 0, "auth")
	insertPhotosNoUploadTestUser(t, db, 7, 1500, 0, "locker")

	insertPhotosNoUploadTestUser(t, db, 8, 1500, 1, "photos")

	insertPhotosNoUploadTestUser(t, db, 9, 1500, 0, "photos")
	if _, err := db.Exec(`UPDATE usage SET photos_file_count = NULL, locker_file_count = NULL WHERE user_id = 9`); err != nil {
		t.Fatalf("failed to clear file counts: %v", err)
	}

	insertPhotosNoUploadTestUser(t, db, 10, 1500, 0, "photos")
	testutil.InsertNotificationHistory(t, db, testutil.NotificationHistoryFixture{UserID: 10, TemplateID: PhotosNoUploadTemplateID, SentTime: 1900})

	insertPhotosNoUploadTestUser(t, db, 11, 1500, 0, "photos")
	if _, err := db.Exec(`UPDATE users SET encrypted_email = NULL, email_decryption_nonce = NULL WHERE user_id = 11`); err != nil {
		t.Fatalf("failed to delete user email: %v", err)
	}

	insertPhotosNoUploadTestUser(t, db, 12, 1600, 0, "photos")
	if _, err := db.Exec(`UPDATE tokens SET is_deleted = true WHERE user_id = 12`); err != nil {
		t.Fatalf("failed to flag token deleted: %v", err)
	}

	candidates, err := repo.GetPhotosNoUploadCandidates(context.Background(), cutoff, createdBefore, 10)
	if err != nil {
		t.Fatalf("GetPhotosNoUploadCandidates() error = %v", err)
	}
	if want := []int64{1, 2, 12, 3}; !slices.Equal(candidates, want) {
		t.Fatalf("candidates = %v, want %v", candidates, want)
	}

	candidates, err = repo.GetPhotosNoUploadCandidates(context.Background(), cutoff, createdBefore, 2)
	if err != nil {
		t.Fatalf("GetPhotosNoUploadCandidates() error = %v", err)
	}
	if want := []int64{1, 2}; !slices.Equal(candidates, want) {
		t.Fatalf("limited candidates = %v, want %v", candidates, want)
	}
}

func insertPhotosNoUploadTestUser(t *testing.T, db *sql.DB, userID int64, creationTime int64, photosFileCount int64, app string) {
	t.Helper()
	testutil.InsertUser(t, db, testutil.UserFixture{
		UserID:       userID,
		Email:        fmt.Sprintf("photos-no-upload-%d@example.com", userID),
		CreationTime: creationTime,
	})
	testutil.InsertUsageWithFileCounts(t, db, userID, photosFileCount)
	testutil.InsertToken(t, db, userID, app, creationTime)
}
