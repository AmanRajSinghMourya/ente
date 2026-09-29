package collections

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/internal/testutil"
	museumcontroller "github.com/ente/museum/pkg/controller"
	"github.com/ente/museum/pkg/controller/public"
	"github.com/ente/museum/pkg/repo"
	timeUtil "github.com/ente/museum/pkg/utils/time"
	"github.com/stretchr/testify/require"
)

type albumShareEmail struct {
	from, to int64
	count    int
}

type recordingCollectionEmails struct {
	albums []albumShareEmail
	joins  chan struct{}
}

func (r *recordingCollectionEmails) QueueAlbumShareEmail(from, to int64, count int) {
	r.albums = append(r.albums, albumShareEmail{from, to, count})
}

func (r *recordingCollectionEmails) OnLinkJoined(int64, int64, ente.CollectionParticipantRole) {
	if r.joins != nil {
		r.joins <- struct{}{}
	}
}

func TestAlbumShareEmailOnlyForNewAccess(t *testing.T) {
	db, collectionRepo, ownerID, shareeID := setupCollectionShareTest(t)
	controller := newBatchShareTestController(db, collectionRepo)
	emails := &recordingCollectionEmails{}
	controller.EmailCtrl = emails
	collectionID := createShareTestCollection(t, collectionRepo, ownerID)
	req := ente.AlterShareRequest{
		CollectionID: collectionID,
		Email:        "sharee@example.com",
		EncryptedKey: b64OfLen(sealedCollectionKeyLen),
	}
	ctx := newBatchShareTestContext(ownerID)
	for range 2 {
		_, err := controller.Share(ctx, req)
		require.NoError(t, err)
	}
	role := ente.COLLABORATOR
	req.Role = &role
	_, err := controller.Share(ctx, req)
	require.NoError(t, err)
	require.Equal(t, []albumShareEmail{{ownerID, shareeID, 1}}, emails.albums)
	actualRole, err := collectionRepo.GetCollectionShareeRole(collectionID, shareeID)
	require.NoError(t, err)
	require.Equal(t, role, *actualRole)

	require.NoError(t, collectionRepo.UnShare(collectionID, shareeID))
	_, err = controller.Share(ctx, req)
	require.NoError(t, err)
	require.Equal(t, []albumShareEmail{{ownerID, shareeID, 1}, {ownerID, shareeID, 1}}, emails.albums)

	lockerID := createShareTestCollection(t, collectionRepo, ownerID)
	_, err = db.Exec(`UPDATE collections SET app = $1 WHERE collection_id = $2`, string(ente.Locker), lockerID)
	require.NoError(t, err)
	req.CollectionID = lockerID
	_, err = controller.Share(ctx, req)
	require.NoError(t, err)
	require.Len(t, emails.albums, 2)
}

func TestAlbumShareEmailUsesSharingAdmin(t *testing.T) {
	db, collectionRepo, ownerID, adminID := setupCollectionShareTest(t)
	recipientID := testutil.InsertUser(t, db, testutil.UserFixture{UserID: 3, Email: "recipient@example.com", CreationTime: 1})
	collectionID := createShareTestCollection(t, collectionRepo, ownerID)
	addShareTestShare(t, collectionRepo, collectionID, ownerID, adminID, ente.ADMIN)
	controller := newBatchShareTestController(db, collectionRepo)
	emails := &recordingCollectionEmails{}
	controller.EmailCtrl = emails
	_, err := controller.Share(newBatchShareTestContext(adminID), ente.AlterShareRequest{
		CollectionID: collectionID,
		Email:        "recipient@example.com",
		EncryptedKey: b64OfLen(sealedCollectionKeyLen),
	})
	require.NoError(t, err)
	require.Equal(t, []albumShareEmail{{adminID, recipientID, 1}}, emails.albums)
}

func TestAlbumShareRestoresLegacyNullShareState(t *testing.T) {
	db, collectionRepo, ownerID, shareeID := setupCollectionShareTest(t)
	collectionID := createShareTestCollection(t, collectionRepo, ownerID)
	addShareTestShare(t, collectionRepo, collectionID, ownerID, shareeID, ente.VIEWER)
	_, err := db.Exec(`UPDATE collection_shares SET is_deleted = NULL WHERE collection_id = $1`, collectionID)
	require.NoError(t, err)
	controller := newBatchShareTestController(db, collectionRepo)
	emails := &recordingCollectionEmails{}
	controller.EmailCtrl = emails
	_, err = controller.Share(newBatchShareTestContext(ownerID), ente.AlterShareRequest{
		CollectionID: collectionID, Email: "sharee@example.com", EncryptedKey: b64OfLen(sealedCollectionKeyLen),
	})
	require.NoError(t, err)
	role, err := collectionRepo.GetCollectionShareeRole(collectionID, shareeID)
	require.NoError(t, err)
	require.Equal(t, ente.VIEWER, *role)
	require.Equal(t, []albumShareEmail{{ownerID, shareeID, 1}}, emails.albums)
}

func TestAlbumShareRejectsDeletedAlbumWithoutEmail(t *testing.T) {
	db, collectionRepo, ownerID, shareeID := setupCollectionShareTest(t)
	collectionID := createShareTestCollection(t, collectionRepo, ownerID)
	addShareTestShare(t, collectionRepo, collectionID, ownerID, shareeID, ente.VIEWER)
	require.NoError(t, collectionRepo.UnShare(collectionID, shareeID))
	_, err := db.Exec(`UPDATE collections SET is_deleted = TRUE WHERE collection_id = $1`, collectionID)
	require.NoError(t, err)
	controller := newBatchShareTestController(db, collectionRepo)
	emails := &recordingCollectionEmails{}
	controller.EmailCtrl = emails
	_, err = controller.Share(newBatchShareTestContext(ownerID), ente.AlterShareRequest{
		CollectionID: collectionID, Email: "sharee@example.com", EncryptedKey: b64OfLen(sealedCollectionKeyLen),
	})
	require.ErrorIs(t, err, ente.ErrCollectionDeleted)
	results, err := controller.BulkShare(newBatchShareTestContext(ownerID), ente.BulkCollectionShareRequest{
		RecipientUserID: shareeID, RecipientEmail: "sharee@example.com", Source: ente.ManualShare,
		Collections: []ente.BulkCollectionShareItem{{
			CollectionID: collectionID, EncryptedKey: b64OfLen(sealedCollectionKeyLen), Role: ente.VIEWER,
		}},
	})
	require.NoError(t, err)
	require.Equal(t, ente.CollectionShareOperationFailed, results[0].Status)
	require.Empty(t, emails.albums)
	var deleted bool
	require.NoError(t, db.QueryRow(`SELECT is_deleted FROM collection_shares WHERE collection_id = $1 AND to_user_id = $2`, collectionID, shareeID).Scan(&deleted))
	require.True(t, deleted)
}

func TestJoinViaLinkKeepsOwnerEmailAndRejectsDeletedAlbum(t *testing.T) {
	db, collectionRepo, ownerID, shareeID := setupCollectionShareTest(t)
	collectionID := createShareTestCollection(t, collectionRepo, ownerID)
	testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{
		UserID: ownerID, Storage: 1_000_000, ExpiryTime: timeUtil.MicrosecondsAfterMinutes(60),
	})
	require.NoError(t, collectionRepo.CollectionLinkRepo.Insert(context.Background(), collectionID, "test-link", 0, 100, false, false, nil))
	controller := newBatchShareTestController(db, collectionRepo)
	controller.CollectionLinkCtrl = &public.CollectionLinkController{CollectionLinkRepo: collectionRepo.CollectionLinkRepo}
	controller.BillingCtrl = &museumcontroller.BillingController{
		UserRepo: &repo.UserRepository{DB: db}, BillingRepo: &repo.BillingRepository{DB: db},
	}
	emails := &recordingCollectionEmails{joins: make(chan struct{}, 1)}
	controller.EmailCtrl = emails
	ctx := newBatchShareTestContext(shareeID)
	ctx.Request.Header.Set("X-Auth-Access-Token", "test-link")
	req := ente.JoinCollectionViaLinkRequest{CollectionID: collectionID, EncryptedKey: b64OfLen(sealedCollectionKeyLen)}
	require.NoError(t, controller.JoinViaLink(ctx, req))
	select {
	case <-emails.joins:
	case <-time.After(time.Second):
		t.Fatal("owner was not notified of link join")
	}
	require.Empty(t, emails.albums)
	require.NoError(t, collectionRepo.UnShare(collectionID, shareeID))
	_, err := db.Exec(`UPDATE collections SET is_deleted = TRUE WHERE collection_id = $1`, collectionID)
	require.NoError(t, err)
	require.ErrorIs(t, controller.JoinViaLink(ctx, req), ente.ErrCollectionDeleted)
	require.Empty(t, emails.albums)
}

func TestBatchShareEmailsOnlyNewRecipients(t *testing.T) {
	db, collectionRepo, ownerID, existingID := setupCollectionShareTest(t)
	newID := testutil.InsertUser(t, db, testutil.UserFixture{UserID: 3, Email: "new@example.com", CreationTime: 1})
	collectionID := createShareTestCollection(t, collectionRepo, ownerID)
	addShareTestShare(t, collectionRepo, collectionID, ownerID, existingID, ente.VIEWER)
	controller := newBatchShareTestController(db, collectionRepo)
	emails := &recordingCollectionEmails{}
	controller.EmailCtrl = emails
	role := ente.COLLABORATOR
	shares := []ente.AlterShareRequest{
		{CollectionID: collectionID, Email: "sharee@example.com", EncryptedKey: b64OfLen(sealedCollectionKeyLen), Role: &role},
		{CollectionID: collectionID, Email: "new@example.com", EncryptedKey: b64OfLen(sealedCollectionKeyLen)},
	}
	for range 2 {
		_, err := controller.BatchShare(newBatchShareTestContext(ownerID), shares)
		require.NoError(t, err)
	}
	require.Equal(t, []albumShareEmail{{ownerID, newID, 1}}, emails.albums)
	actualRole, err := collectionRepo.GetCollectionShareeRole(collectionID, existingID)
	require.NoError(t, err)
	require.Equal(t, role, *actualRole)
	var sharedAt int64
	require.NoError(t, db.QueryRow(`SELECT shared_at FROM collection_shares
		WHERE collection_id = $1 AND to_user_id = $2`, collectionID, existingID).Scan(&sharedAt))
	require.EqualValues(t, 1, sharedAt, "permission changes preserve the original share time")
}

func TestBulkShareEmailsGroupNewPhotosAlbums(t *testing.T) {
	db, collectionRepo, ownerID, shareeID := setupCollectionShareTest(t)
	controller := newBatchShareTestController(db, collectionRepo)
	controller.UserRepo = &repo.UserRepository{DB: db}
	emails := &recordingCollectionEmails{}
	controller.EmailCtrl = emails
	firstID := createShareTestCollection(t, collectionRepo, ownerID)
	secondID := createShareTestCollection(t, collectionRepo, ownerID)
	existingID := createShareTestCollection(t, collectionRepo, ownerID)
	lockerID := createShareTestCollection(t, collectionRepo, ownerID)
	_, err := db.Exec(`UPDATE collections SET app = $1 WHERE collection_id = $2`, string(ente.Locker), lockerID)
	require.NoError(t, err)
	addShareTestShare(t, collectionRepo, existingID, ownerID, shareeID, ente.VIEWER)
	req := ente.BulkCollectionShareRequest{
		RecipientUserID: shareeID, RecipientEmail: "sharee@example.com", Source: ente.ManualShare,
	}
	for _, id := range []int64{firstID, secondID, existingID, lockerID, -1} {
		req.Collections = append(req.Collections, ente.BulkCollectionShareItem{
			CollectionID: id, EncryptedKey: b64OfLen(sealedCollectionKeyLen), Role: ente.VIEWER,
		})
	}
	for range 2 {
		results, err := controller.BulkShare(newBatchShareTestContext(ownerID), req)
		require.NoError(t, err)
		require.Equal(t, ente.CollectionShareOperationFailed, results[4].Status)
	}
	require.Equal(t, []albumShareEmail{{ownerID, shareeID, 2}}, emails.albums)

	setShareTestFamilyAdmin(t, db, ownerID, ownerID)
	setShareTestFamilyAdmin(t, db, shareeID, ownerID)
	req.Source = ente.AutomaticShare
	req.Collections = []ente.BulkCollectionShareItem{{
		CollectionID: createShareTestCollection(t, collectionRepo, ownerID),
		EncryptedKey: b64OfLen(sealedCollectionKeyLen), Role: ente.VIEWER,
	}}
	results, err := controller.BulkShare(newBatchShareTestContext(ownerID), req)
	require.NoError(t, err)
	require.Equal(t, ente.CollectionShared, results[0].Status)
	require.Len(t, emails.albums, 1)
}

func TestShareConcurrentRetriesReportNewAccessOnce(t *testing.T) {
	_, collectionRepo, ownerID, shareeID := setupCollectionShareTest(t)
	collectionID := createShareTestCollection(t, collectionRepo, ownerID)
	const attempts = 8
	newShares := make(chan bool, attempts)
	errors := make(chan error, attempts)
	start := make(chan struct{})
	var workers sync.WaitGroup
	for range attempts {
		workers.Add(1)
		go func() {
			defer workers.Done()
			<-start
			isNew, err := collectionRepo.Share(collectionID, ownerID, shareeID, "key", ente.VIEWER, 42)
			newShares <- isNew
			errors <- err
		}()
	}
	close(start)
	workers.Wait()
	newCount := 0
	for range attempts {
		require.NoError(t, <-errors)
		if <-newShares {
			newCount++
		}
	}
	require.Equal(t, 1, newCount)

	newRecipients, err := collectionRepo.BatchShare(context.Background(), collectionID, ownerID, []repo.CollectionShareItem{
		{ToUserID: shareeID, EncryptedKey: "key", Role: ente.ADMIN},
		{ToUserID: 999999, EncryptedKey: "key", Role: ente.VIEWER},
	}, 43)
	require.Error(t, err)
	require.Empty(t, newRecipients)
	role, err := collectionRepo.GetCollectionShareeRole(collectionID, shareeID)
	require.NoError(t, err)
	require.Equal(t, ente.VIEWER, *role)
}
