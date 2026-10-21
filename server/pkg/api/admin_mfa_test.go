package api_test

import (
	"database/sql"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/internal/testutil"
	"github.com/ente/museum/pkg/api"
	"github.com/ente/museum/pkg/controller"
	"github.com/ente/museum/pkg/controller/discord"
	"github.com/ente/museum/pkg/controller/user"
	"github.com/ente/museum/pkg/middleware"
	"github.com/ente/museum/pkg/repo"
	"github.com/ente/museum/pkg/repo/passkey"
	"github.com/ente/museum/pkg/utils/auth"
	"github.com/gin-gonic/gin"
	"github.com/patrickmn/go-cache"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAdminMFARequiresFreshToken(t *testing.T) {
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	previousAdmins := viper.Get("internal.admins")
	viper.Set("internal.admins", []int{13401})
	t.Cleanup(func() { viper.Set("internal.admins", previousAdmins) })

	now := time.Now().UnixMicro()
	for _, id := range []int64{13401, 13402} {
		testutil.InsertUser(t, db, testutil.UserFixture{
			UserID: id, Email: fmt.Sprintf("admin-mfa-%d@example.com", id), CreationTime: now,
		})
	}
	exec := func(t *testing.T, query string, args ...any) {
		t.Helper()
		_, err := db.Exec(query, args...)
		require.NoError(t, err)
	}
	exec(t, `INSERT INTO srp_auth(user_id,srp_user_id,salt,verifier)
		VALUES(13402,'00000000-0000-0000-0000-000000013402','test','test')`)
	exec(t, `INSERT INTO passkeys(id,user_id,friendly_name)
		VALUES('00000000-0000-0000-0000-000000013402',13402,'test')`)

	authRepo := &repo.UserAuthRepository{DB: db}
	userRepo := &repo.UserRepository{DB: db, SecretEncryptionKey: testutil.SecretEncryptionKey(), HashingKey: testutil.HashingKey()}
	userController := &user.UserController{UserAuthRepo: authRepo}
	closedDB, err := sql.Open("postgres", "sslmode=disable")
	require.NoError(t, err)
	require.NoError(t, closedDB.Close())
	for _, session := range []struct {
		token string
		age   time.Duration
	}{
		{"fresh-admin", time.Minute},
		{"stale-admin", 11 * time.Minute},
	} {
		require.NoError(t, authRepo.AddToken(13401, ente.Photos, session.token, "127.0.0.1", "test"))
		hash := auth.HashToken(session.token)
		// Keep normal session validity independent of the token's creation age.
		exec(t, `UPDATE tokens SET creation_time=$1,last_used_at=$2 WHERE token_hash=$3`, now-session.age.Microseconds(), now, hash[:])
	}

	for _, action := range []struct {
		name, path, body string
		initialEmail     bool
	}{
		{"remove_passkeys", "disable-passkeys", `{"userID":13402}`, true},
		{"disable_email_mfa", "update-email-mfa", `{"userID":13402,"emailMFA":false}`, true},
		{"enable_email_mfa", "update-email-mfa", `{"userID":13402,"emailMFA":true}`, false},
	} {
		t.Run(action.name, func(t *testing.T) {
			for _, tc := range []struct {
				name, token string
				lookupFails bool
				status      int
			}{
				{name: "stale", token: "stale-admin", status: http.StatusBadRequest},
				{name: "fresh", token: "fresh-admin", status: http.StatusOK},
				{name: "lookup_failure", token: "fresh-admin", lookupFails: true, status: http.StatusInternalServerError},
			} {
				t.Run(tc.name, func(t *testing.T) {
					exec(t, `UPDATE users SET email_mfa=$1,is_two_factor_enabled=true WHERE user_id=13402`, action.initialEmail)
					exec(t, `UPDATE passkeys SET deleted_at=NULL WHERE user_id=13402`)
					h := &api.AdminHandler{
						UserAuthRepo: authRepo, UserRepo: userRepo, UserController: userController,
						PasskeyController: &controller.PasskeyController{Repo: &passkey.Repository{DB: db}, UserRepo: userRepo},
						DiscordController: &discord.DiscordController{},
					}
					if tc.lookupFails {
						h.UserAuthRepo = &repo.UserAuthRepository{DB: closedDB}
					}
					mw := &middleware.AuthMiddleware{UserAuthRepo: authRepo, UserController: userController, Cache: cache.New(time.Minute, 0)}
					router := gin.New()
					admin := router.Group("/admin", mw.TokenAuthMiddleware(nil), mw.AdminAuthMiddleware())
					admin.POST("/user/disable-passkeys", h.RemovePasskeys)
					admin.POST("/user/update-email-mfa", h.UpdateEmailMFA)
					req := httptest.NewRequest(http.MethodPost, "/admin/user/"+action.path, strings.NewReader(action.body))
					req.Header.Set("Content-Type", "application/json")
					req.Header.Set("X-Auth-Token", tc.token)
					req.Header.Set("X-Client-Package", "io.ente.photos")
					response := httptest.NewRecorder()
					router.ServeHTTP(response, req)

					assert.Equal(t, tc.status, response.Code, response.Body.String())
					if tc.status == http.StatusBadRequest {
						assert.Contains(t, response.Body.String(), "Token is too old")
					}
					wantEmail, wantPasskeys := action.initialEmail, 1
					if tc.status == http.StatusOK {
						if action.name == "remove_passkeys" {
							wantPasskeys = 0
						} else {
							wantEmail = !action.initialEmail
						}
					}
					var emailMFA, totp bool
					var passkeys int
					require.NoError(t, db.QueryRow(`SELECT email_mfa,is_two_factor_enabled FROM users WHERE user_id=13402`).Scan(&emailMFA, &totp))
					require.NoError(t, db.QueryRow(`SELECT count(*) FROM passkeys WHERE user_id=13402 AND deleted_at IS NULL`).Scan(&passkeys))
					assert.Equal(t, wantEmail, emailMFA)
					assert.Equal(t, wantPasskeys, passkeys)
					assert.True(t, totp, "TOTP must remain enabled")
				})
			}
		})
	}
}
