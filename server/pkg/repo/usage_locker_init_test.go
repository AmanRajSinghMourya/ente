package repo

import (
	"testing"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/internal/testutil"
	"github.com/stretchr/testify/require"
)

func TestInitializeLockerUsageMatchesFallback(t *testing.T) {
	for _, empty := range []bool{false, true} {
		name := "files"
		if empty {
			name = "empty"
		}
		t.Run(name, func(t *testing.T) {
			_, db, userID := setupCollectionMembershipTest(t)
			var want, total int64
			if !empty {
				first := insertLockerUsageTestCollection(t, db, userID, ente.Locker)
				second := insertLockerUsageTestCollection(t, db, userID, ente.Locker)
				fileID := insertObjectTestFile(t, db, userID)
				linkObjectTestFileToCollection(t, db, first, fileID, userID)
				linkObjectTestFileToCollection(t, db, second, fileID, userID)
				insertObjectTestKey(t, db, fileID, ente.FILE, "init-file", 100, []string{"b2-eu-cen"})
				insertObjectTestKey(t, db, fileID, ente.THUMBNAIL, "init-thumbnail", 10, []string{"b2-eu-cen"})
				_, err := db.Exec(`UPDATE collection_files SET is_deleted = TRUE WHERE file_id = $1`, fileID)
				require.NoError(t, err)

				deleted := insertObjectTestFile(t, db, userID)
				linkObjectTestFileToCollection(t, db, first, deleted, userID)
				insertObjectTestKey(t, db, deleted, ente.FILE, "init-deleted", 1000, []string{"b2-eu-cen"})
				_, err = db.Exec(`UPDATE object_keys SET is_deleted = TRUE WHERE file_id = $1`, deleted)
				require.NoError(t, err)

				other := testutil.InsertUser(t, db, testutil.UserFixture{UserID: 2, Email: "other@ente.io", CreationTime: 1})
				foreign := insertObjectTestFile(t, db, other)
				linkObjectTestFileToCollection(t, db, first, foreign, other)
				insertObjectTestKey(t, db, foreign, ente.FILE, "init-foreign", 2000, []string{"b2-eu-cen"})
				photos := insertLockerUsageTestCollection(t, db, userID, ente.Photos)
				photo := insertObjectTestFile(t, db, userID)
				linkObjectTestFileToCollection(t, db, photos, photo, userID)
				insertObjectTestKey(t, db, photo, ente.FILE, "init-photo", 3000, []string{"b2-eu-cen"})
				want = 110
				total = 3110
			}
			_, err := db.Exec(`UPDATE usage SET storage_consumed = $2 WHERE user_id = $1`, userID, total)
			require.NoError(t, err)
			repository := &UsageRepository{DB: db}
			fallback, err := repository.GetLockerStorageUsage(t.Context(), []int64{userID})
			require.NoError(t, err)
			require.Equal(t, want, fallback.TotalUsage)
			initialized, err := repository.InitializeLockerUsage(t.Context(), userID)
			require.NoError(t, err)
			require.True(t, initialized)
			assertLockerUsage(t, db, userID, total, want)
			initialized, err = repository.InitializeLockerUsage(t.Context(), userID)
			require.NoError(t, err)
			require.False(t, initialized)
		})
	}
}

func TestInitializeLockerUsageRejectsStaleSnapshot(t *testing.T) {
	collections, db, userID := setupCollectionMembershipTest(t)
	collectionID := insertLockerUsageTestCollection(t, db, userID, ente.Locker)
	fileID := insertObjectTestFile(t, db, userID)
	insertObjectTestKey(t, db, fileID, ente.FILE, "snapshot-file", 100, []string{"b2-eu-cen"})
	_, err := db.Exec(`UPDATE usage SET storage_consumed = 100 WHERE user_id = $1`, userID)
	require.NoError(t, err)
	repository := &UsageRepository{DB: db}
	snapshot, err := repository.readLockerUsageSnapshot(t.Context(), userID)
	require.NoError(t, err)
	require.NoError(t, collections.AddFiles(t.Context(), collectionID, userID,
		[]ente.CollectionFileItem{collectionMembershipTestItem(fileID)}, userID, ente.Locker))
	initialized, err := repository.publishInitialLockerUsage(t.Context(), userID, snapshot)
	require.NoError(t, err)
	require.False(t, initialized)
	initialized, err = repository.InitializeLockerUsage(t.Context(), userID)
	require.NoError(t, err)
	require.True(t, initialized)
	assertLockerUsage(t, db, userID, 100, 100)
}

func TestInitializeFileCountsAllowsPhotosStorageChanges(t *testing.T) {
	_, db, userID := setupCollectionMembershipTest(t)
	collectionID := insertLockerUsageTestCollection(t, db, userID, ente.Photos)
	fileID := insertObjectTestFile(t, db, userID)
	linkObjectTestFileToCollection(t, db, collectionID, fileID, userID)
	repository := &UsageRepository{DB: db}
	snapshot, err := repository.readFileCountInitSnapshot(t.Context(), userID)
	require.NoError(t, err)
	tx, err := db.BeginTx(t.Context(), nil)
	require.NoError(t, err)
	defer tx.Rollback()
	_, err = applyFileStorageChange(t.Context(), tx, userID, fileID, 10)
	require.NoError(t, err)
	require.NoError(t, tx.Commit())
	initialized, err := repository.publishInitialFileCounts(t.Context(), userID, snapshot)
	require.NoError(t, err)
	require.True(t, initialized, "Photos-only size changes must not reject a file-count snapshot")
	_, photos, locker, err := repository.GetStoredFileCounts(t.Context(), userID)
	require.NoError(t, err)
	require.Equal(t, int64(1), photos)
	require.Zero(t, locker)
}
