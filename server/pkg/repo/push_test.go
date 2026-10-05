package repo

import (
	"os"
	"testing"

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
