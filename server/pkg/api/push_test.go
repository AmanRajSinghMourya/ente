package api

import (
	"encoding/base64"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/internal/testutil"
	"github.com/ente/museum/pkg/controller"
	"github.com/ente/museum/pkg/repo"
	"github.com/ente/museum/pkg/utils/auth"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestPushRegistrationBindsRequestSession(t *testing.T) {
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	testutil.InsertUser(t, db, testutil.UserFixture{UserID: 1, Email: "user@example.com", CreationTime: 1})
	require.NoError(t, (&repo.UserAuthRepository{DB: db}).AddToken(1, ente.Photos, "authenticated-session", "", ""))
	router := gin.New()
	handler := PushHandler{PushController: &controller.PushController{PushRepo: &repo.PushTokenRepository{DB: db}}}
	router.POST("/push/token", handler.AddToken)
	body := fmt.Sprintf(`{"fcmToken":"device", "apnsToken":"apns", "sessionTokenHash":"%s"}`, base64.StdEncoding.EncodeToString([]byte("untrusted-session")))
	request := httptest.NewRequest(http.MethodPost, "/push/token", strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-Auth-User-ID", "1")
	request.Header.Set("X-Auth-Token", "authenticated-session")
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	require.Equal(t, http.StatusOK, response.Code)
	var owner int64
	var hash []byte
	require.NoError(t, db.QueryRow(`SELECT user_id, session_token_hash FROM push_tokens WHERE fcm_token = 'device'`).Scan(&owner, &hash))
	expected := auth.HashToken("authenticated-session")
	require.Equal(t, int64(1), owner)
	require.Equal(t, expected[:], hash)
}

func TestPushRegistrationPlatform(t *testing.T) {
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	for _, id := range []int64{1, 2} {
		testutil.InsertUser(t, db, testutil.UserFixture{UserID: id, Email: fmt.Sprintf("user%d@example.com", id), CreationTime: 1})
	}
	router := gin.New()
	handler := PushHandler{PushController: &controller.PushController{PushRepo: &repo.PushTokenRepository{DB: db}}}
	router.POST("/push/token", handler.AddToken)
	for _, tc := range []struct {
		name, fields, platform string
		userID                 int64
	}{
		{"legacy omission", `"apnsToken":"apns"`, "ios", 1},
		{"android reassignment", `"platform":"android","apnsToken":null`, "android", 2},
		{"ios reassignment", `"platform":"ios","apnsToken":"apns"`, "ios", 1},
		{"omission without APNs", `"apnsToken":null`, "ios", 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			require.NoError(t, (&repo.UserAuthRepository{DB: db}).AddToken(tc.userID, ente.Photos, tc.name, "", ""))
			body := fmt.Sprintf(`{"fcmToken":"device",%s}`, tc.fields)
			request := httptest.NewRequest(http.MethodPost, "/push/token", strings.NewReader(body))
			request.Header.Set("Content-Type", "application/json")
			request.Header.Set("X-Auth-User-ID", fmt.Sprint(tc.userID))
			request.Header.Set("X-Auth-Token", tc.name)
			response := httptest.NewRecorder()
			router.ServeHTTP(response, request)
			require.Equal(t, http.StatusOK, response.Code, response.Body.String())
			var owner int64
			var platform, apns string
			var hash []byte
			require.NoError(t, db.QueryRow(`SELECT user_id, platform, apns_token, session_token_hash FROM push_tokens WHERE fcm_token = 'device'`).Scan(&owner, &platform, &apns, &hash))
			require.Equal(t, tc.userID, owner)
			require.Equal(t, tc.platform, platform)
			expectedHash := auth.HashToken(tc.name)
			require.Equal(t, expectedHash[:], hash)
			if strings.Contains(tc.fields, "null") {
				require.Empty(t, apns)
			} else {
				require.Equal(t, "apns", apns)
			}
		})
	}
	for _, platform := range []string{`""`, `"web"`, `"Android"`, `null`, `1`} {
		t.Run("reject "+platform, func(t *testing.T) {
			body := fmt.Sprintf(`{"fcmToken":"invalid-device","platform":%s}`, platform)
			request := httptest.NewRequest(http.MethodPost, "/push/token", strings.NewReader(body))
			request.Header.Set("Content-Type", "application/json")
			request.Header.Set("X-Auth-User-ID", "1")
			response := httptest.NewRecorder()
			router.ServeHTTP(response, request)
			require.Equal(t, http.StatusBadRequest, response.Code, response.Body.String())
			var count int
			require.NoError(t, db.QueryRow(`SELECT count(*) FROM push_tokens WHERE fcm_token = 'invalid-device'`).Scan(&count))
			require.Zero(t, count)
		})
	}
}
