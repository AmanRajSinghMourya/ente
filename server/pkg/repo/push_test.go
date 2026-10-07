package repo

import (
	"crypto/sha256"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/internal/testutil"
	"github.com/stretchr/testify/require"
)

func TestPushTokenRegistrationMigration(t *testing.T) {
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	tx, err := db.Begin()
	require.NoError(t, err)
	defer tx.Rollback()
	_, err = tx.Exec(`CREATE TEMP TABLE push_tokens (fcm_token TEXT, apns_token TEXT) ON COMMIT DROP;
		INSERT INTO push_tokens VALUES ('with-apns', 'apns'), ('without-apns', '');`)
	require.NoError(t, err)
	up, err := os.ReadFile("migrations/149_push_token_registration.up.sql")
	require.NoError(t, err)
	_, err = tx.Exec(string(up))
	require.NoError(t, err)
	_, err = tx.Exec(`INSERT INTO push_tokens (fcm_token) VALUES ('old-server')`)
	require.NoError(t, err)
	var count int
	require.NoError(t, tx.QueryRow(`SELECT count(*) FROM push_tokens WHERE platform = 'ios' AND session_token_hash IS NULL`).Scan(&count))
	require.Equal(t, 3, count)
	_, err = tx.Exec(`UPDATE push_tokens SET platform = 'android' WHERE fcm_token = 'without-apns'`)
	require.NoError(t, err)
	down, err := os.ReadFile("migrations/149_push_token_registration.down.sql")
	require.NoError(t, err)
	_, err = tx.Exec(string(down))
	require.NoError(t, err)
	require.NoError(t, tx.QueryRow(`SELECT count(*) FROM push_tokens`).Scan(&count))
	require.Equal(t, 3, count)
}

func TestGetTokensToBeNotifiedFiltersPlatformBeforeLimit(t *testing.T) {
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	testutil.InsertUser(t, db, testutil.UserFixture{UserID: 1, Email: "user@example.com", CreationTime: 1})
	_, err := db.Exec(`INSERT INTO push_tokens (user_id, fcm_token, platform, last_notified_at) VALUES
		(1, 'android-one', 'android', 0), (1, 'android-two', 'android', 0),
		(1, 'ios-one', 'ios', 0), (1, 'ios-two', 'ios', 0), (1, 'ios-recent', 'ios', 100)`)
	require.NoError(t, err)
	r := PushTokenRepository{DB: db}
	tokens, err := r.GetTokensToBeNotified(100, 2)
	require.NoError(t, err)
	var fcmTokens []string
	for _, token := range tokens {
		fcmTokens = append(fcmTokens, token.FCMToken)
	}
	require.ElementsMatch(t, []string{"ios-one", "ios-two"}, fcmTokens)
}

func TestPushLookupsExcludeRevokedSessions(t *testing.T) {
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	for _, id := range []int64{1, 2} {
		testutil.InsertUser(t, db, testutil.UserFixture{UserID: id, Email: fmt.Sprintf("user%d@example.com", id), CreationTime: 1})
	}
	_, err := db.Exec(`INSERT INTO remote_store(user_id, key_name, key_value) VALUES(1, 'internalUser', 'true')`)
	require.NoError(t, err)
	authRepo := &UserAuthRepository{DB: db}
	for _, session := range []struct {
		token  string
		userID int64
	}{
		{"active", 1}, {"revoked", 1}, {"other-user", 2},
	} {
		require.NoError(t, authRepo.AddToken(session.userID, ente.Photos, session.token, "", ""))
	}
	revokedHash := sha256.Sum256([]byte("revoked"))
	_, err = authRepo.RemoveTokenByHash(1, revokedHash[:])
	require.NoError(t, err)
	for _, token := range []string{"active", "revoked", "other-user", "missing"} {
		hash := sha256.Sum256([]byte(token))
		_, err := db.Exec(`INSERT INTO push_tokens(user_id, fcm_token, session_token_hash, last_notified_at) VALUES(1, $1, $2, 0)`, token, hash[:])
		require.NoError(t, err)
	}
	_, err = db.Exec(`INSERT INTO push_tokens(user_id, fcm_token, last_notified_at) VALUES(1, 'legacy', 0)`)
	require.NoError(t, err)
	r := &PushTokenRepository{DB: db}
	t.Run("album alerts", func(t *testing.T) {
		tokens, err := r.GetFCMTokensForAlbumShare(t.Context(), []int64{1})
		require.NoError(t, err)
		require.Equal(t, []string{"active"}, tokens)
	})
	t.Run("silent sync", func(t *testing.T) {
		tokens, err := r.GetTokensToBeNotified(1, 10)
		require.NoError(t, err)
		var fcmTokens []string
		for _, token := range tokens {
			fcmTokens = append(fcmTokens, token.FCMToken)
		}
		require.ElementsMatch(t, []string{"active", "legacy"}, fcmTokens)
	})
}

func TestPushRegistrationRejectsRevokedSessionAfterAccountSwitch(t *testing.T) {
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	authRepo := &UserAuthRepository{DB: db}
	pushRepo := &PushTokenRepository{DB: db}
	for _, id := range []int64{1, 2} {
		testutil.InsertUser(t, db, testutil.UserFixture{UserID: id, Email: fmt.Sprintf("user%d@example.com", id), CreationTime: 1})
		require.NoError(t, authRepo.AddToken(id, ente.Photos, fmt.Sprint(id), "", ""))
	}
	oldHash, newHash := sha256.Sum256([]byte("1")), sha256.Sum256([]byte("2"))
	request := ente.PushTokenRequest{FCMToken: "device"}
	require.NoError(t, pushRepo.AddToken(1, oldHash[:], request))
	_, err := authRepo.RemoveTokenByHash(1, oldHash[:])
	require.NoError(t, err)
	var count int
	require.NoError(t, db.QueryRow(`SELECT count(*) FROM push_tokens`).Scan(&count))
	require.Zero(t, count)
	require.NoError(t, pushRepo.AddToken(2, newHash[:], request))
	for _, tc := range []struct {
		name   string
		userID int64
		hash   []byte
	}{
		{"revoked", 1, oldHash[:]}, {"wrong owner", 1, newHash[:]}, {"missing", 1, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			require.ErrorIs(t, pushRepo.AddToken(tc.userID, tc.hash, request), ente.ErrAuthenticationRequired)
			var owner int64
			var hash []byte
			require.NoError(t, db.QueryRow(`SELECT user_id, session_token_hash FROM push_tokens WHERE fcm_token = 'device'`).Scan(&owner, &hash))
			require.Equal(t, int64(2), owner)
			require.Equal(t, newHash[:], hash)
		})
	}
}

func TestPushRegistrationWaitsForSessionRevocation(t *testing.T) {
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	userID := testutil.InsertUser(t, db, testutil.UserFixture{Email: "registration-race@example.com", CreationTime: 1})
	require.NoError(t, (&UserAuthRepository{DB: db}).AddToken(userID, ente.Photos, "session", "", ""))
	hash := sha256.Sum256([]byte("session"))
	revocation, err := db.Begin()
	require.NoError(t, err)
	defer revocation.Rollback()
	_, err = revocation.Exec(`UPDATE tokens SET is_deleted = true WHERE token_hash = $1`, hash[:])
	require.NoError(t, err)
	var pid int
	require.NoError(t, revocation.QueryRow(`SELECT pg_backend_pid()`).Scan(&pid))
	done := make(chan error, 1)
	go func() {
		done <- (&PushTokenRepository{DB: db}).AddToken(userID, hash[:], ente.PushTokenRequest{FCMToken: "device"})
	}()
	require.Eventually(t, func() bool {
		var blocked bool
		require.NoError(t, db.QueryRow(`SELECT EXISTS(SELECT 1 FROM pg_stat_activity
			WHERE datname = current_database() AND $1 = ANY(pg_blocking_pids(pid)))`, pid).Scan(&blocked))
		return blocked
	}, 5*time.Second, 10*time.Millisecond)
	require.NoError(t, revocation.Commit())
	select {
	case err := <-done:
		require.ErrorIs(t, err, ente.ErrAuthenticationRequired)
	case <-time.After(5 * time.Second):
		t.Fatal("push registration did not finish")
	}
	var count int
	require.NoError(t, db.QueryRow(`SELECT count(*) FROM push_tokens`).Scan(&count))
	require.Zero(t, count)
}
