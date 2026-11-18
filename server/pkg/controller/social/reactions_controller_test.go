package social

import (
	"context"
	"database/sql"
	"fmt"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	socialentity "github.com/ente/museum/ente/social"
	"github.com/ente/museum/internal/testutil"
	"github.com/ente/museum/pkg/controller/access"
	"github.com/ente/museum/pkg/repo"
	publicrepo "github.com/ente/museum/pkg/repo/public"
	socialrepo "github.com/ente/museum/pkg/repo/social"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

type fileLikePushRecorder chan int64

func (r fileLikePushRecorder) NotifyFileLike(_ context.Context, recipientID int64) {
	r <- recipientID
}

func TestFileLikeRecipients(t *testing.T) {
	for _, name := range []string{"signed-in", "public-link", "self", "revoked owner", "comment like", "album like", "removed file", "failed write"} {
		t.Run(name, func(t *testing.T) {
			c, db, req, pushes := setupFileLikeTest(t)
			wantPush, wantErr := true, false
			switch name {
			case "public-link":
				anonID := "anon_123456789012345678901"
				_, err := db.Exec(`INSERT INTO anon_users(id, collection_id, cipher, nonce) VALUES($1, $2, 'name', 'nonce')`, anonID, req.CollectionID)
				require.NoError(t, err)
				req.Actor = Actor{AnonUserID: &anonID}
				req.RequireAccess = false
			case "self":
				ownerID := int64(1)
				req.Actor = Actor{UserID: &ownerID}
				wantPush = false
			case "revoked owner":
				_, err := db.Exec(`UPDATE collection_shares SET is_deleted=true WHERE collection_id=$1 AND to_user_id=1`, req.CollectionID)
				require.NoError(t, err)
				wantPush = false
			case "comment like":
				commentID := "cmt_123456789012345678901"
				require.NoError(t, c.CommentsRepo.Insert(t.Context(), socialentity.Comment{ID: commentID, CollectionID: req.CollectionID, FileID: req.FileID, UserID: 1, Cipher: "comment", Nonce: "nonce"}))
				req.CommentID = &commentID
				wantPush = false
			case "album like":
				req.FileID = nil
				wantPush = false
			case "removed file":
				_, err := db.Exec(`UPDATE collection_files SET action='REMOVE' WHERE collection_id=$1 AND file_id=$2`, req.CollectionID, req.FileID)
				require.NoError(t, err)
				wantPush, wantErr = false, true
			case "failed write":
				req.Cipher = ""
				wantPush, wantErr = false, true
			}
			id, err := c.Upsert(fileLikeTestContext(), req)
			if wantErr {
				require.Error(t, err)
			} else {
				require.NoError(t, err)
				saved, err := c.Repo.GetByID(t.Context(), id)
				require.NoError(t, err)
				require.Equal(t, req.Cipher, saved.Cipher)
			}
			if wantPush {
				select {
				case push := <-pushes:
					require.Equal(t, int64(1), push, "the file owner differs from the album owner and actor")
				case <-time.After(time.Second):
					t.Fatal("missing file like push")
				}
			}
			select {
			case push := <-pushes:
				t.Fatalf("unexpected push to %d", push)
			case <-time.After(50 * time.Millisecond):
			}
		})
	}
}

func TestReactionRetriesAndRelikesDoNotPushAgain(t *testing.T) {
	for _, name := range []string{"signed-in", "public-link", "comment", "album"} {
		t.Run(name, func(t *testing.T) {
			c, db, req, pushes := setupFileLikeTest(t)
			switch name {
			case "public-link":
				anonID := "anon_123456789012345678901"
				_, err := db.Exec(`INSERT INTO anon_users(id, collection_id, cipher, nonce) VALUES($1, $2, 'name', 'nonce')`, anonID, req.CollectionID)
				require.NoError(t, err)
				req.Actor = Actor{AnonUserID: &anonID}
				req.RequireAccess = false
			case "comment":
				commentID := "cmt_123456789012345678901"
				require.NoError(t, c.CommentsRepo.Insert(t.Context(), socialentity.Comment{ID: commentID, CollectionID: req.CollectionID, FileID: req.FileID, UserID: 1, Cipher: "comment", Nonce: "nonce"}))
				req.CommentID = &commentID
			case "album":
				req.FileID = nil
			}
			const requests = 12
			var wg sync.WaitGroup
			errors := make(chan error, requests)
			ids := make(chan string, requests)
			for range requests {
				wg.Go(func() {
					id, err := c.Upsert(fileLikeTestContext(), req)
					errors <- err
					ids <- id
				})
			}
			wg.Wait()
			close(errors)
			close(ids)
			for err := range errors {
				require.NoError(t, err)
			}
			var savedID string
			for id := range ids {
				if savedID == "" {
					savedID = id
				}
				require.Equal(t, savedID, id)
			}
			if req.FileID != nil && req.CommentID == nil {
				select {
				case push := <-pushes:
					require.Equal(t, int64(1), push, "only the file owner receives the initial like push")
				case <-time.After(time.Second):
					t.Fatal("missing initial like push")
				}
			}
			before, err := c.Repo.GetByID(t.Context(), savedID)
			require.NoError(t, err)
			req.ID = savedID
			_, err = c.Upsert(fileLikeTestContext(), req)
			require.NoError(t, err)
			require.NoError(t, c.Repo.SoftDeleteByID(t.Context(), savedID, before.UserID, before.AnonUserID))
			deleted, err := c.Repo.GetByID(t.Context(), savedID)
			require.NoError(t, err)
			require.True(t, deleted.IsDeleted)
			require.Empty(t, deleted.Cipher)
			require.Empty(t, deleted.Nonce)
			req.ID = ""
			req.Cipher = "updated-cipher"
			req.Nonce = "updated-nonce"
			id, err := c.Upsert(fileLikeTestContext(), req)
			require.NoError(t, err)
			require.Equal(t, savedID, id)
			after, err := c.Repo.GetByID(t.Context(), savedID)
			require.NoError(t, err)
			require.False(t, after.IsDeleted)
			require.Equal(t, req.Cipher, after.Cipher)
			require.Equal(t, req.Nonce, after.Nonce)
			require.Equal(t, before.CreatedAt, after.CreatedAt)
			select {
			case <-pushes:
				t.Fatal("retry or unlike/re-like produced another push")
			case <-time.After(50 * time.Millisecond):
			}
		})
	}
}

func setupFileLikeTest(t *testing.T) (*ReactionsController, *sql.DB, UpsertReactionRequest, fileLikePushRecorder) {
	t.Helper()
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	_, err := db.Exec(`TRUNCATE reactions, comments, anon_users CASCADE`)
	require.NoError(t, err)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	for _, userID := range []int64{1, 2, 3} {
		testutil.InsertUser(t, db, testutil.UserFixture{UserID: userID, Email: fmt.Sprintf("user%d@photo-like.test", userID), CreationTime: 1})
	}
	var collectionID, fileID int64
	require.NoError(t, db.QueryRow(`INSERT INTO collections(owner_id, encrypted_key, key_decryption_nonce, name, type, attributes, updation_time, app)
		VALUES (2, 'key', 'nonce', 'Collaborative album', 'album', '{}', 1, 'photos') RETURNING collection_id`).Scan(&collectionID))
	require.NoError(t, db.QueryRow(`INSERT INTO files(owner_id, file_decryption_header, thumbnail_decryption_header, metadata_decryption_header, encrypted_metadata, updation_time, info)
		VALUES (1, 'file', 'thumbnail', 'metadata', 'data', 1, '{}') RETURNING file_id`).Scan(&fileID))
	_, err = db.Exec(`INSERT INTO collection_files(collection_id, file_id, encrypted_key, key_decryption_nonce, updation_time, c_owner_id, f_owner_id)
		VALUES ($1, $2, 'key', 'nonce', 1, 2, 1)`, collectionID, fileID)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO collection_shares(collection_id, from_user_id, to_user_id, encrypted_key, updation_time, role_type, shared_at)
		VALUES ($1, 2, 1, 'key', 1, 'VIEWER', 1), ($1, 2, 3, 'key', 1, 'VIEWER', 1)`, collectionID)
	require.NoError(t, err)
	files := &repo.FileRepository{DB: db}
	collections := &repo.CollectionRepository{DB: db, CollectionLinkRepo: publicrepo.NewCollectionLinkRepository(db, "")}
	pushes := make(fileLikePushRecorder, 16)
	c := &ReactionsController{
		Repo: &socialrepo.ReactionsRepository{DB: db}, CommentsRepo: &socialrepo.CommentsRepository{DB: db},
		CollectionRepo: collections, FileRepo: files, AccessCtrl: access.NewAccessController(collections, files), PushCtrl: pushes,
	}
	actorID := int64(3)
	return c, db, UpsertReactionRequest{Actor: Actor{UserID: &actorID}, CollectionID: collectionID, FileID: &fileID, Cipher: "cipher", Nonce: "nonce", RequireAccess: true}, pushes
}

func fileLikeTestContext() *gin.Context {
	ctx, _ := gin.CreateTestContext(httptest.NewRecorder())
	ctx.Request = httptest.NewRequest("POST", "/reactions", nil)
	return ctx
}
