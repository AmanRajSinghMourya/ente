package api

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/internal/testutil"
	"github.com/ente/museum/pkg/controller/access"
	castctrl "github.com/ente/museum/pkg/controller/cast"
	"github.com/ente/museum/pkg/controller/collections"
	"github.com/ente/museum/pkg/controller/public"
	"github.com/ente/museum/pkg/middleware"
	"github.com/ente/museum/pkg/repo"
	castrepo "github.com/ente/museum/pkg/repo/cast"
	publicrepo "github.com/ente/museum/pkg/repo/public"
	"github.com/ente/museum/pkg/utils/auth"
	"github.com/gin-gonic/gin"
	"github.com/patrickmn/go-cache"
	"github.com/stretchr/testify/require"
)

func TestCollectionAppIsolation(t *testing.T) {
	for _, app := range []ente.App{ente.Photos, ente.Locker} {
		t.Run(string(app), func(t *testing.T) {
			testutil.WithServerRoot(t)
			db := testutil.RequireTestDB(t)
			testutil.ResetTables(t, db)
			_, err := db.Exec(`DELETE FROM queue WHERE queue_name = $1`, repo.TrashCollectionQueueV3)
			require.NoError(t, err)
			t.Cleanup(func() {
				_, err := db.Exec(`DELETE FROM queue WHERE queue_name = $1`, repo.TrashCollectionQueueV3)
				require.NoError(t, err)
				testutil.ResetTables(t, db)
			})
			ownerID := testutil.InsertUser(t, db, testutil.UserFixture{UserID: 1, Email: "owner@ente.com", CreationTime: 1})
			testutil.InsertUsage(t, db, ownerID, 0)
			otherID := testutil.InsertUser(t, db, testutil.UserFixture{UserID: 2, Email: "other@ente.com", CreationTime: 1})
			linkRepo := publicrepo.NewCollectionLinkRepository(db, "")
			collectionRepo := &repo.CollectionRepository{
				DB: db, CollectionLinkRepo: linkRepo, QueueRepo: &repo.QueueRepository{DB: db},
				SecretEncryptionKey: testutil.SecretEncryptionKey(),
				TrashRepo:           &repo.TrashRepository{DB: db},
			}
			castRepo := &castrepo.Repository{DB: db}
			accessCtrl := access.NewAccessController(collectionRepo, &repo.FileRepository{DB: db})
			owned := make(map[ente.App]int64)
			shared := make(map[ente.App]int64)
			for _, collectionApp := range []ente.App{ente.Photos, ente.Locker} {
				for _, userID := range []int64{ownerID, otherID} {
					collection, err := collectionRepo.Create(ente.Collection{
						Owner: ente.CollectionUser{ID: userID}, App: string(collectionApp), Type: "album",
						EncryptedKey: "key", KeyDecryptionNonce: "nonce", Name: "collection", UpdationTime: 1,
					})
					require.NoError(t, err)
					if userID == ownerID {
						owned[collectionApp] = collection.ID
						require.NoError(t, linkRepo.Insert(t.Context(), collection.ID, string(collectionApp), 0, 0, false, false, nil))
						code, err := castRepo.AddCode(t.Context(), "key", nil, "127.0.0.1", "device")
						require.NoError(t, err)
						_, err = castRepo.InsertCastData(t.Context(), ownerID, code, collection.ID, string(collectionApp), "payload")
						require.NoError(t, err)
					} else {
						shared[collectionApp] = collection.ID
						_, err = db.Exec(`INSERT INTO collection_shares(collection_id, from_user_id, to_user_id, encrypted_key, updation_time, role_type, shared_at)
							VALUES ($1, $2, $3, 'shared-key', 1, $4, 1)`, collection.ID, otherID, ownerID, ente.VIEWER)
						require.NoError(t, err)
					}
				}
			}
			userAuthRepo := &repo.UserAuthRepository{DB: db}
			const token = "collection-app-test-token"
			require.NoError(t, userAuthRepo.AddToken(ownerID, app, token, "127.0.0.1", "test"))
			authMiddleware := &middleware.AuthMiddleware{UserAuthRepo: userAuthRepo, Cache: cache.New(time.Minute, time.Minute)}
			collectionHandler := &CollectionHandler{Controller: &collections.CollectionController{
				AccessCtrl: accessCtrl, CollectionRepo: collectionRepo, CastRepo: castRepo,
				FileRepo:           &repo.FileRepository{DB: db},
				CollectionLinkCtrl: &public.CollectionLinkController{CollectionLinkRepo: linkRepo},
			}}
			gin.SetMode(gin.TestMode)
			router := gin.New()
			storage := router.Group("/", authMiddleware.TokenAuthMiddleware(nil), middleware.RejectAuthApp())
			storage.GET("/collections/:collectionID", collectionHandler.GetCollectionByID)
			storage.DELETE("/collections/v3/:collectionID", collectionHandler.TrashV3)
			storage.POST("/collections/add-files", collectionHandler.AddFiles)
			storage.POST("/collections/restore-files", collectionHandler.RestoreFiles)
			request := func(method, path string, clientApp ente.App) *httptest.ResponseRecorder {
				req := httptest.NewRequest(method, path, nil)
				req.Header.Set("X-Auth-Token", token)
				req.Header.Set("X-Client-Package", "io.ente."+string(clientApp))
				recorder := httptest.NewRecorder()
				router.ServeHTTP(recorder, req)
				return recorder
			}
			otherApp := ente.Photos
			if app == ente.Photos {
				otherApp = ente.Locker
			}
			for _, operation := range []string{"add-files", "restore-files"} {
				t.Run(operation, func(t *testing.T) {
					for _, sourceApp := range []ente.App{app, otherApp} {
						for _, state := range []string{"modern", "legacy", "legacy-mixed", "legacy-shared"} {
							if (state == "legacy-mixed" || state == "legacy-shared") && sourceApp == app {
								continue
							}
							t.Run(fmt.Sprintf("%s_%s", sourceApp, state), func(t *testing.T) {
								source, err := collectionRepo.Create(ente.Collection{
									Owner: ente.CollectionUser{ID: ownerID}, App: string(sourceApp), Type: "album",
									EncryptedKey: "key", KeyDecryptionNonce: "nonce", Name: "source", UpdationTime: 1,
								})
								require.NoError(t, err)
								if state == "legacy-shared" {
									source.ID, source.Owner.ID = shared[sourceApp], otherID
								}
								var fileApp any = string(sourceApp)
								if state != "modern" {
									fileApp = nil
								}
								var fileID int64
								require.NoError(t, db.QueryRow(`INSERT INTO files(owner_id, app, file_decryption_header,
								thumbnail_decryption_header, metadata_decryption_header, encrypted_metadata, updation_time, info)
								VALUES ($1, $2, 'header', 'header', 'header', 'metadata', 1, '{}') RETURNING file_id`, ownerID, fileApp).Scan(&fileID))
								_, err = db.Exec(`INSERT INTO collection_files(collection_id, file_id, encrypted_key,
								key_decryption_nonce, is_deleted, updation_time, c_owner_id, f_owner_id)
								VALUES ($1, $2, 'key', 'nonce', false, 1, $3, $4)`, source.ID, fileID, source.Owner.ID, ownerID)
								require.NoError(t, err)
								if state == "legacy-mixed" {
									_, err = db.Exec(`INSERT INTO collection_files(collection_id, file_id, encrypted_key,
										key_decryption_nonce, is_deleted, updation_time, c_owner_id, f_owner_id)
										VALUES ($1, $2, 'key', 'nonce', true, 1, $3, $3)`, owned[app], fileID, ownerID)
									require.NoError(t, err)
								}
								_, err = db.Exec(`INSERT INTO object_keys(file_id, o_type, object_key, size, datacenters)
								VALUES ($1, 'file', $2, 1073741824, ARRAY['b2-eu-cen']::s3region[])`, fileID, fmt.Sprintf("isolation-%d", fileID))
								require.NoError(t, err)
								_, err = db.Exec("UPDATE usage SET storage_consumed=storage_consumed+1073741824 WHERE user_id=$1", ownerID)
								require.NoError(t, err)
								if operation == "restore-files" {
									_, err = db.Exec("UPDATE collection_files SET is_deleted=true WHERE file_id=$1", fileID)
									require.NoError(t, err)
									_, err = db.Exec(`INSERT INTO trash(file_id, collection_id, user_id, delete_by, updated_at)
									VALUES ($1, $2, $3, $4, 1)`, fileID, source.ID, ownerID, time.Now().Add(time.Hour).UnixMicro())
									require.NoError(t, err)
								}
								usageRepo := &repo.UsageRepository{DB: db}
								before, err := usageRepo.GetLockerStorageUsage(t.Context(), []int64{ownerID})
								require.NoError(t, err)
								body, err := json.Marshal(ente.AddFilesRequest{CollectionID: owned[app], Files: []ente.CollectionFileItem{{
									ID: fileID, EncryptedKey: base64.StdEncoding.EncodeToString(make([]byte, 48)),
									KeyDecryptionNonce: base64.StdEncoding.EncodeToString(make([]byte, 24)),
								}}})
								require.NoError(t, err)
								request := httptest.NewRequest(http.MethodPost, "/collections/"+operation, bytes.NewReader(body))
								request.Header.Set("Content-Type", "application/json")
								request.Header.Set("X-Auth-Token", token)
								request.Header.Set("X-Client-Package", "io.ente."+string(app))
								response := httptest.NewRecorder()
								router.ServeHTTP(response, request)
								wantStatus := http.StatusOK
								if sourceApp != app && state != "legacy-mixed" {
									wantStatus = http.StatusForbidden
								}
								after, err := usageRepo.GetLockerStorageUsage(t.Context(), []int64{ownerID})
								require.NoError(t, err)
								require.Equal(t, wantStatus, response.Code, response.Body.String())
								require.Equal(t, before.TotalUsage, after.TotalUsage, "adding an existing file must not reclassify its bytes")
							})
						}
					}
				})
			}
			t.Run("point_access", func(t *testing.T) {
				for _, ids := range []map[ente.App]int64{owned, shared} {
					for _, targetApp := range []ente.App{app, otherApp} {
						response := request(http.MethodGet, fmt.Sprintf("/collections/%d", ids[targetApp]), app)
						wantStatus := http.StatusForbidden
						if targetApp == app {
							wantStatus = http.StatusOK
						}
						require.Equal(t, wantStatus, response.Code, response.Body.String())
					}
				}
			})
			t.Run("cross_app_delete", func(t *testing.T) {
				id := owned[otherApp]
				path := fmt.Sprintf("/collections/v3/%d?collectionID=%d&keepFiles=false", id, id)
				response := request(http.MethodDelete, path, app)
				require.Equal(t, http.StatusForbidden, response.Code, response.Body.String())
				response = request(http.MethodDelete, path, otherApp)
				require.Equal(t, http.StatusUnauthorized, response.Code, response.Body.String())
				collection, err := collectionRepo.Get(id)
				require.NoError(t, err)
				require.False(t, collection.IsDeleted)
				require.Len(t, collection.PublicURLs, 1)
				_, _, err = castRepo.GetCollectionAndCasterIDForToken(t.Context(), string(otherApp))
				require.NoError(t, err)
				var queued bool
				require.NoError(t, db.QueryRow(`SELECT EXISTS (SELECT 1 FROM queue WHERE queue_name = $1 AND item = $2)`, repo.TrashCollectionQueueV3, strconv.FormatInt(id, 10)).Scan(&queued))
				require.False(t, queued)
			})
			t.Run("same_app_delete", func(t *testing.T) {
				id := owned[app]
				response := request(http.MethodDelete, fmt.Sprintf("/collections/v3/%d?collectionID=%d&keepFiles=false", id, id), app)
				require.Equal(t, http.StatusOK, response.Code, response.Body.String())
				collection, err := collectionRepo.Get(id)
				require.NoError(t, err)
				require.True(t, collection.IsDeleted)
				var queued bool
				require.NoError(t, db.QueryRow(`SELECT EXISTS (SELECT 1 FROM queue WHERE queue_name = $1 AND item = $2)`, repo.TrashCollectionQueueV3, strconv.FormatInt(id, 10)).Scan(&queued))
				require.True(t, queued)
			})
			t.Run("cast_access", func(t *testing.T) {
				ctx, _ := gin.CreateTestContext(httptest.NewRecorder())
				ctx.Request = httptest.NewRequest(http.MethodGet, "/cast/collection", nil)
				ctx.Request.Header.Set("X-Client-Package", "io.ente."+string(app))
				_, present := auth.GetAuthenticatedApp(ctx)
				require.False(t, present)
				castCtrl := castctrl.NewController(castRepo, accessCtrl)
				castCtx, err := castCtrl.GetCollectionAndCasterIDForToken(ctx, string(otherApp))
				require.NoError(t, err)
				require.Equal(t, owned[otherApp], castCtx.CollectionID)
				require.Equal(t, ownerID, castCtx.UserID)
			})
			t.Run("non_member_access", func(t *testing.T) {
				_, err := db.Exec(`DELETE FROM collection_shares WHERE to_user_id = $1`, ownerID)
				require.NoError(t, err)
				for _, id := range shared {
					response := request(http.MethodGet, fmt.Sprintf("/collections/%d", id), app)
					require.Equal(t, http.StatusNotFound, response.Code, response.Body.String())
				}
			})
		})
	}
}
