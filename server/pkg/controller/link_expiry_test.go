package controller

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/internal/testutil"
	"github.com/ente/museum/pkg/repo"
	"github.com/ente/museum/pkg/repo/public"
	"github.com/ente/museum/pkg/utils/auth"
	"github.com/stretchr/testify/require"
	"golang.org/x/crypto/nacl/box"
)

func TestLinkExpiryReminders(t *testing.T) {
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	testutil.InsertUser(t, db, testutil.UserFixture{UserID: 1, Email: "expiry@example.com", CreationTime: 1})
	_, err := db.Exec(`INSERT INTO remote_store(user_id,key_name,key_value) VALUES(1,'internalUser','true')`)
	require.NoError(t, err)
	require.NoError(t, (&repo.UserAuthRepository{DB: db}).AddToken(1, ente.Photos, "expiry-session", "", ""))
	hash := auth.HashToken("expiry-session")
	publicKey, privateKey, err := box.GenerateKey(rand.Reader)
	require.NoError(t, err)
	c := &PushController{PushRepo: &repo.PushTokenRepository{DB: db}, TaskLockRepo: &repo.TaskLockRepository{DB: db}, HostName: "expiry-host"}
	for _, platform := range []string{"android", "ios"} {
		require.NoError(t, c.AddToken(1, hash[:], ente.PushTokenRequest{FCMToken: platform, Platform: &platform, NotificationKey: publicKey[:]}))
	}
	android := "android"
	require.NoError(t, c.AddToken(1, hash[:], ente.PushTokenRequest{FCMToken: "keyless", Platform: &android}))
	now := time.Now().UTC()
	now = time.Date(now.Year(), now.Month(), now.Day(), 9, 0, 0, 0, time.UTC).In(time.FixedZone("west", -10*60*60))
	tomorrow := time.Date(now.UTC().Year(), now.UTC().Month(), now.UTC().Day()+1, 0, 0, 0, 0, time.UTC)
	want := map[int64]int64{}
	var firstID int64
	for i, tc := range []struct {
		expires           time.Time
		disabled, deleted bool
		app               string
		selected          bool
	}{
		{tomorrow, false, false, "photos", true},
		{tomorrow.Add(24*time.Hour - time.Microsecond), false, false, "photos", true},
		{tomorrow.Add(-time.Microsecond), false, false, "photos", false},
		{tomorrow.Add(24 * time.Hour), false, false, "photos", false},
		{time.UnixMicro(0), false, false, "photos", false},
		{tomorrow, true, false, "photos", false},
		{tomorrow, false, true, "photos", false},
		{tomorrow, false, false, "locker", false},
	} {
		var id int64
		require.NoError(t, db.QueryRow(`INSERT INTO collections(owner_id, encrypted_key, key_decryption_nonce, name, type, attributes, updation_time, app, is_deleted)
			VALUES(1,'key','nonce','Album','album','{}',1,$1,$2) RETURNING collection_id`, tc.app, tc.deleted).Scan(&id))
		_, err := db.Exec(`INSERT INTO public_collection_tokens(collection_id, access_token, valid_till, is_disabled) VALUES($1,$2,$3,$4)`, id, fmt.Sprint("expiry-", i), tc.expires.UnixMicro(), tc.disabled)
		require.NoError(t, err)
		if tc.selected {
			want[id] = tc.expires.UnixMicro()
		}
		if i == 0 {
			firstID = id
		}
	}
	got := map[int64]int64{}
	requests := 0
	c.fcm = &fcmClient{projectID: "test", httpClient: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		var msg wireMsg
		require.NoError(t, json.NewDecoder(r.Body).Decode(&msg))
		require.Equal(t, "android", msg.Message.Token)
		require.Len(t, msg.Message.Data, 1)
		ciphertext, err := base64.StdEncoding.DecodeString(msg.Message.Data["notificationCiphertext"])
		require.NoError(t, err)
		plaintext, ok := box.OpenAnonymous(nil, ciphertext, publicKey, privateKey)
		require.True(t, ok)
		var event struct {
			EventType    string `json:"eventType"`
			CollectionID int64  `json:"collectionID"`
			ExpiresAt    int64  `json:"expiresAt"`
		}
		require.NoError(t, json.Unmarshal(plaintext, &event))
		require.Equal(t, "shared_link_expiring", event.EventType)
		got[event.CollectionID] = event.ExpiresAt
		requests++
		return jsonResponse(http.StatusOK, "{}"), nil
	})}}
	links := public.NewCollectionLinkRepository(db, "")
	c.SendLinkExpiryReminders(links, now)
	require.Equal(t, want, got)
	require.Equal(t, 2, requests)
	_, err = c.TaskLockRepo.ReleaseLocksBy(c.HostName)
	require.NoError(t, err)
	c.HostName = "second-host"
	c.SendLinkExpiryReminders(links, now)
	require.Equal(t, 2, requests)
	_, err = db.Exec(`UPDATE public_collection_tokens SET valid_till=$1 WHERE collection_id=$2`, tomorrow.AddDate(0, 0, 7).UnixMicro(), firstID)
	require.NoError(t, err)
	_, err = db.Exec(`UPDATE task_lock SET lock_until=0 WHERE task_name='shared-link-expiry'`)
	require.NoError(t, err)
	got = map[int64]int64{}
	c.SendLinkExpiryReminders(links, now.AddDate(0, 0, 7))
	require.Equal(t, map[int64]int64{firstID: tomorrow.AddDate(0, 0, 7).UnixMicro()}, got)
	_, err = db.Exec(`DELETE FROM remote_store WHERE user_id=1; DELETE FROM task_lock WHERE task_name='shared-link-expiry'`)
	require.NoError(t, err)
	c.SendLinkExpiryReminders(links, now.AddDate(0, 0, 7))
	require.Equal(t, 3, requests)
}
