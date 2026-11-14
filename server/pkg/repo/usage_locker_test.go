package repo

import (
	"database/sql"
	"strconv"
	"testing"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/pkg/repo/public"
	"github.com/ente/museum/pkg/utils/s3config"
	"github.com/lib/pq"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/require"
)

func TestLockerUsageTracksFileLifecycle(t *testing.T) {
	for _, app := range []ente.App{ente.Locker, ente.Photos} {
		t.Run(string(app), func(t *testing.T) {
			repository, db, userID := setupCollectionMembershipTest(t)
			viper.Reset()
			viper.Set("s3.hot_storage.primary", "b2-eu-cen")
			t.Cleanup(viper.Reset)
			fileRepo := &FileRepository{
				DB:                db,
				S3Config:          s3config.NewS3Config(),
				QueueRepo:         &QueueRepository{DB: db},
				ObjectRepo:        &ObjectRepository{DB: db, QueueRepo: &QueueRepository{DB: db}},
				ObjectCleanupRepo: &ObjectCleanupRepository{DB: db},
				ObjectCopiesRepo:  &ObjectCopiesRepository{DB: db},
			}
			repository.TrashRepo.FileRepo = fileRepo
			repository.TrashRepo.FileLinkRepo = public.NewFileLinkRepo(db)
			_, err := db.Exec(`UPDATE usage SET locker_usage = 0, photos_file_count = 0, locker_file_count = 0
				WHERE user_id = $1`, userID)
			require.NoError(t, err)
			first := insertLockerUsageTestCollection(t, db, userID, app)
			second := insertLockerUsageTestCollection(t, db, userID, app)
			file := ente.File{
				OwnerID: userID, CollectionID: first, UpdationTime: 1,
				EncryptedKey: "key", KeyDecryptionNonce: "nonce",
				File:      ente.FileAttributes{ObjectKey: "locker-usage-file", DecryptionHeader: "header"},
				Thumbnail: ente.FileAttributes{ObjectKey: "locker-usage-thumbnail", DecryptionHeader: "header"},
				Metadata:  ente.FileAttributes{EncryptedData: "metadata", DecryptionHeader: "header"},
				Info:      &ente.FileInfo{FileSize: 100, ThumbnailSize: 10},
			}
			stage := func(keys ...string) {
				_, err := db.Exec(`INSERT INTO temp_objects(object_key, expiration_time)
					SELECT unnest($1::text[]), 1`, pq.Array(keys))
				require.NoError(t, err)
			}
			t.Cleanup(func() {
				_, err := db.Exec(`DELETE FROM queue WHERE item = ANY($1)
					OR (queue_name = $2 AND item = $3)`, pq.Array([]string{
					"locker-usage-file", "locker-usage-thumbnail", "locker-usage-replacement",
					"locker-usage-replacement-thumbnail", "locker-usage-new-thumbnail",
				}), DeleteEmbeddingsQueue, strconv.FormatInt(file.ID, 10))
				require.NoError(t, err)
			})
			assertUsage := func(total int64) {
				t.Helper()
				var locker int64
				if app == ente.Locker {
					locker = total
				}
				assertLockerUsage(t, db, userID, total, locker)
			}

			stage(file.File.ObjectKey, file.Thumbnail.ObjectKey)
			file, total, err := fileRepo.Create(file, 100, 10, 110, userID, app)
			require.NoError(t, err)
			require.Equal(t, int64(110), total)
			assertUsage(110)

			oldObjects := []string{file.File.ObjectKey, file.Thumbnail.ObjectKey}
			file.File.ObjectKey = "locker-usage-replacement"
			file.Thumbnail.ObjectKey = "locker-usage-replacement-thumbnail"
			file.Info.FileSize, file.Info.ThumbnailSize = 200, 20
			file.UpdationTime = 2
			stage(file.File.ObjectKey, file.Thumbnail.ObjectKey)
			require.NoError(t, fileRepo.Update(file, 200, 20, 110, oldObjects,
				[]string{file.File.ObjectKey, file.Thumbnail.ObjectKey}, app))
			assertUsage(220)

			oldThumbnail := file.Thumbnail.ObjectKey
			thumbnail := ente.FileAttributes{ObjectKey: "locker-usage-new-thumbnail", DecryptionHeader: "header"}
			stage(thumbnail.ObjectKey)
			require.NoError(t, fileRepo.UpdateThumbnail(t.Context(), file.ID, userID, thumbnail, 30, 10, &oldThumbnail, app))
			assertUsage(230)

			items := []ente.CollectionFileItem{collectionMembershipTestItem(file.ID)}
			require.NoError(t, repository.AddFiles(t.Context(), second, userID, items, userID, app))
			assertUsage(230)
			require.NoError(t, repository.MoveFiles(t.Context(), second, first, items, userID, userID, app))
			assertUsage(230)
			trash := ente.TrashRequest{TrashItems: []ente.TrashItemRequest{{FileID: file.ID, CollectionID: second}}}
			require.NoError(t, repository.TrashRepo.TrashFiles(t.Context(), userID, trash))
			assertUsage(230)
			require.NoError(t, repository.RestoreFiles(t.Context(), userID, second, items, app))
			assertUsage(230)
			require.NoError(t, repository.TrashRepo.TrashFiles(t.Context(), userID, trash))
			require.NoError(t, repository.TrashRepo.Delete(t.Context(), userID, []int64{file.ID}))
			assertUsage(0)
		})
	}
}

func TestLockerMembershipChangesCreditUsageOnce(t *testing.T) {
	for _, action := range []string{"add", "move", "restore"} {
		t.Run(action, func(t *testing.T) {
			repository, db, userID := setupCollectionMembershipTest(t)
			source := insertLockerUsageTestCollection(t, db, userID, ente.Locker)
			first := insertLockerUsageTestCollection(t, db, userID, ente.Locker)
			second := insertLockerUsageTestCollection(t, db, userID, ente.Locker)
			fileID := insertObjectTestFile(t, db, userID)
			linkObjectTestFileToCollection(t, db, source, fileID, userID)
			// Legacy memberships can lack the denormalized file owner used for byte attribution.
			_, err := db.Exec(`UPDATE collection_files SET f_owner_id = NULL WHERE file_id = $1`, fileID)
			require.NoError(t, err)
			insertObjectTestKey(t, db, fileID, ente.FILE, "membership-file", 100, []string{"b2-eu-cen"})
			insertObjectTestKey(t, db, fileID, ente.THUMBNAIL, "membership-thumbnail", 10, []string{"b2-eu-cen"})
			_, err = db.Exec(`UPDATE usage SET storage_consumed = 110, locker_usage = 0 WHERE user_id = $1`, userID)
			require.NoError(t, err)
			items := []ente.CollectionFileItem{collectionMembershipTestItem(fileID), collectionMembershipTestItem(fileID)}
			switch action {
			case "add":
				err = repository.AddFiles(t.Context(), first, userID, items, userID, ente.Locker)
			case "move":
				err = repository.MoveFiles(t.Context(), first, source, items, userID, userID, ente.Locker)
			case "restore":
				repository.TrashRepo.FileLinkRepo = public.NewFileLinkRepo(db)
				require.NoError(t, repository.TrashRepo.TrashFiles(t.Context(), userID, ente.TrashRequest{
					TrashItems: []ente.TrashItemRequest{{FileID: fileID, CollectionID: source}},
				}))
				assertLockerUsage(t, db, userID, 110, 0)
				err = repository.RestoreFiles(t.Context(), userID, first, items[:1], ente.Locker)
			}
			require.NoError(t, err)
			assertLockerUsage(t, db, userID, 110, 110)
			for _, collectionID := range []int64{second, first} {
				require.NoError(t, repository.AddFiles(t.Context(), collectionID, userID, items, userID, ente.Locker))
				assertLockerUsage(t, db, userID, 110, 110)
			}
		})
	}
}

func TestConcurrentLockerAddsCreditUsageOnce(t *testing.T) {
	repository, db, userID := setupCollectionMembershipTest(t)
	first := insertLockerUsageTestCollection(t, db, userID, ente.Locker)
	second := insertLockerUsageTestCollection(t, db, userID, ente.Locker)
	fileID := insertObjectTestFile(t, db, userID)
	insertObjectTestKey(t, db, fileID, ente.FILE, "concurrent-membership-file", 110, []string{"b2-eu-cen"})
	_, err := db.Exec(`UPDATE usage SET storage_consumed = 110, locker_usage = 0 WHERE user_id = $1`, userID)
	require.NoError(t, err)
	results := make(chan error, 2)
	runFileLockRace(t, db, fileID, func() {
		for _, collectionID := range []int64{first, second} {
			go func() {
				results <- repository.AddFiles(t.Context(), collectionID, userID,
					[]ente.CollectionFileItem{collectionMembershipTestItem(fileID)}, userID, ente.Locker)
			}()
		}
	})
	for range 2 {
		require.NoError(t, <-results)
	}
	assertLockerUsage(t, db, userID, 110, 110)
	var memberships int
	require.NoError(t, db.QueryRow(`SELECT COUNT(*) FROM collection_files WHERE file_id = $1`, fileID).Scan(&memberships))
	require.Equal(t, 2, memberships)
}

func TestApplyUsageChangeInvalidatesNegativeLockerUsage(t *testing.T) {
	_, db, userID := setupCollectionMembershipTest(t)
	_, err := db.Exec(`UPDATE usage SET storage_consumed = 100, locker_usage = 10 WHERE user_id = $1`, userID)
	require.NoError(t, err)
	tx, err := db.BeginTx(t.Context(), nil)
	require.NoError(t, err)
	defer tx.Rollback()
	_, err = applyUsageChange(t.Context(), tx, userID, usageChange{LockerStorageDelta: -11})
	require.NoError(t, err)
	require.NoError(t, tx.Commit())
	var storage int64
	var locker sql.NullInt64
	require.NoError(t, db.QueryRow(`SELECT storage_consumed, locker_usage FROM usage WHERE user_id = $1`, userID).Scan(&storage, &locker))
	require.Equal(t, int64(100), storage)
	require.False(t, locker.Valid)
}

func insertLockerUsageTestCollection(t *testing.T, db *sql.DB, userID int64, app ente.App) int64 {
	t.Helper()
	collectionID := insertObjectTestCollection(t, db, userID)
	_, err := db.Exec(`UPDATE collections SET app = $2 WHERE collection_id = $1`, collectionID, app)
	require.NoError(t, err)
	return collectionID
}

func assertLockerUsage(t *testing.T, db *sql.DB, userID, wantTotal, wantLocker int64) {
	t.Helper()
	var total, locker int64
	require.NoError(t, db.QueryRow(`SELECT storage_consumed, locker_usage FROM usage WHERE user_id = $1`, userID).Scan(&total, &locker))
	require.Equal(t, wantTotal, total, "combined storage")
	require.Equal(t, wantLocker, locker, "stored Locker storage")
	usage, err := (&UsageRepository{DB: db}).GetLockerStorageUsage(t.Context(), []int64{userID})
	require.NoError(t, err)
	require.Equal(t, wantLocker, usage.TotalUsage, "returned Locker storage")
}
