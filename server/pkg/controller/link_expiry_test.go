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
	require.NoError(t, c.AddToken(1, hash[:], ente.PushTokenRequest{FCMToken: "another-android", Platform: &android, NotificationKey: publicKey[:]}))
	testutil.InsertUser(t, db, testutil.UserFixture{UserID: 2, Email: "second-owner@example.com", CreationTime: 1})
	_, err = db.Exec(`INSERT INTO remote_store(user_id,key_name,key_value) VALUES(2,'internalUser','true')`)
	require.NoError(t, err)
	require.NoError(t, (&repo.UserAuthRepository{DB: db}).AddToken(2, ente.Photos, "second-session", "", ""))
	secondHash := auth.HashToken("second-session")
	require.NoError(t, c.AddToken(2, secondHash[:], ente.PushTokenRequest{FCMToken: "second-android", Platform: &android, NotificationKey: publicKey[:]}))
	now := time.Now().UTC()
	now = time.Date(now.Year(), now.Month(), now.Day(), 9, 0, 0, 0, time.UTC).In(time.FixedZone("west", -10*60*60))
	windowEnd := now.Add(24 * time.Hour)
	want := map[int64]int64{}
	var firstID int64
	for i, tc := range []struct {
		expires           time.Time
		disabled, deleted bool
		app               string
		selected          bool
	}{
		{now.Add(2 * time.Hour), false, false, "photos", true},
		{windowEnd, false, false, "photos", true},
		{now.Add(time.Hour), false, false, "photos", true},
		{now, false, false, "photos", false},
		{now.Add(-time.Microsecond), false, false, "photos", false},
		{windowEnd.Add(time.Microsecond), false, false, "photos", false},
		{time.UnixMicro(0), false, false, "photos", false},
		{now.Add(time.Hour), true, false, "photos", false},
		{now.Add(time.Hour), false, true, "photos", false},
		{now.Add(time.Hour), false, false, "locker", false},
	} {
		var id int64
		ownerID := int64(1)
		if i == 1 {
			ownerID = 2
		}
		require.NoError(t, db.QueryRow(`INSERT INTO collections(owner_id, encrypted_key, key_decryption_nonce, name, type, attributes, updation_time, app, is_deleted)
			VALUES($3,'key','nonce','Album','album','{}',1,$1,$2) RETURNING collection_id`, tc.app, tc.deleted, ownerID).Scan(&id))
		_, err := db.Exec(`INSERT INTO public_collection_tokens(collection_id, access_token, valid_till, is_disabled) VALUES($1,$2,$3,$4)`, id, fmt.Sprint("expiry-", i), tc.expires.UnixMicro(), tc.disabled)
		require.NoError(t, err)
		if tc.selected {
			want[id] = tc.expires.UnixMicro()
		}
		if i == 0 {
			firstID = id
		}
	}
	gotTokens := []string{}
	requests := 0
	c.fcm = &fcmClient{projectID: "test", httpClient: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		var msg struct {
			Message struct {
				Token   string            `json:"token"`
				Data    map[string]string `json:"data"`
				Android struct {
					TTL string `json:"ttl"`
				} `json:"android"`
			} `json:"message"`
		}
		require.NoError(t, json.NewDecoder(r.Body).Decode(&msg))
		require.Len(t, msg.Message.Data, 1)
		ciphertext, err := base64.StdEncoding.DecodeString(msg.Message.Data["notificationCiphertext"])
		require.NoError(t, err)
		plaintext, ok := box.OpenAnonymous(nil, ciphertext, publicKey, privateKey)
		require.True(t, ok)
		var event map[string]any
		require.NoError(t, json.Unmarshal(plaintext, &event))
		require.Equal(t, map[string]any{"eventType": "shared_link_expiring"}, event)
		if msg.Message.Token == "second-android" {
			require.Equal(t, "86400s", msg.Message.Android.TTL)
		} else {
			require.Equal(t, "3600s", msg.Message.Android.TTL)
		}
		gotTokens = append(gotTokens, msg.Message.Token)
		requests++
		return jsonResponse(http.StatusOK, "{}"), nil
	})}}
	links := public.NewCollectionLinkRepository(db, "")
	selected, err := links.GetExpiringLinks(t.Context(), now.UnixMicro(), windowEnd.UnixMicro())
	require.NoError(t, err)
	got := map[int64]int64{}
	for _, link := range selected {
		got[link.CollectionID] = link.ExpiresAt
	}
	require.Equal(t, want, got)
	c.SendLinkExpiryReminders(links, now)
	require.ElementsMatch(t, []string{"android", "another-android", "second-android"}, gotTokens)
	require.Equal(t, 3, requests)
	_, err = c.TaskLockRepo.ReleaseLocksBy(c.HostName)
	require.NoError(t, err)
	c.HostName = "second-host"
	c.SendLinkExpiryReminders(links, now)
	require.Equal(t, 3, requests)
	_, err = db.Exec(`UPDATE public_collection_tokens SET valid_till=$1 WHERE collection_id=$2`, now.AddDate(0, 0, 7).Add(time.Hour).UnixMicro(), firstID)
	require.NoError(t, err)
	_, err = db.Exec(`UPDATE task_lock SET lock_until=0 WHERE task_name='shared-link-expiry'`)
	require.NoError(t, err)
	gotTokens = nil
	c.SendLinkExpiryReminders(links, now.AddDate(0, 0, 7))
	require.ElementsMatch(t, []string{"android", "another-android"}, gotTokens)
	_, err = db.Exec(`DELETE FROM remote_store WHERE user_id=1; DELETE FROM task_lock WHERE task_name='shared-link-expiry'`)
	require.NoError(t, err)
	c.SendLinkExpiryReminders(links, now.AddDate(0, 0, 7))
	require.Equal(t, 5, requests)
}
