package user

import (
	"fmt"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/ente/cache"
	"github.com/ente/museum/internal/testutil"
	"github.com/ente/museum/pkg/controller/usercache"
	"github.com/ente/museum/pkg/repo"
	"github.com/ente/museum/pkg/repo/passkey"
	storagebonusrepo "github.com/ente/museum/pkg/repo/storagebonus"
)

func TestGetDetailsV2ReportsPhotosUsageWithinFamily(t *testing.T) {
	const gib int64 = 1 << 30
	for _, tc := range []struct {
		name         string
		lockerFactor int64
	}{
		{name: "photos only"},
		{name: "photos and locker", lockerFactor: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			controller, db, ctx := setupLockerUsageControllerTest(t)
			ctx.Request = httptest.NewRequest("GET", "/users/details/v2?memoryCount=false", nil)
			controller.UserAuthRepo = &repo.UserAuthRepository{DB: db}
			controller.PasskeyRepo = &passkey.Repository{DB: db}
			controller.UserCacheController = &usercache.Controller{
				StoreBonusRepo: &storagebonusrepo.Repository{DB: db},
				UserCache:      cache.NewUserCache(),
			}
			controller.FamilyController.UserRepo = controller.UserRepo
			controller.FamilyController.UserCacheCtrl = controller.UserCacheController

			adminID := int64(101)
			for _, member := range []struct {
				id     int64
				status ente.MemberStatus
				photos int64
				locker int64
			}{
				{id: adminID, status: ente.SELF, photos: 50 * gib, locker: 2 * gib},
				{id: 102, status: ente.ACCEPTED, photos: 3 * gib, locker: gib},
				{id: 103, status: ente.INVITED, photos: 7 * gib, locker: 4 * gib},
			} {
				insertLockerUsageTestUser(t, db, member.id, &adminID)
				insertLockerUsageTestFamilyMember(t, db, adminID, member.id, member.status)
				lockerUsage := member.locker * tc.lockerFactor
				testutil.InsertUsage(t, db, member.id, member.photos+lockerUsage)
				if lockerUsage > 0 {
					insertLockerUsageTestLockerFile(t, db, member.id, lockerUsage)
				}
				testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{
					UserID:     member.id,
					Storage:    200 * gib,
					ExpiryTime: time.Now().Add(24 * time.Hour).UnixMicro(),
					ProductID:  ente.FamilyPlanProductID,
				})
			}

			for _, app := range []ente.App{ente.Photos, ente.Locker} {
				for _, requester := range []struct {
					id    int64
					usage int64
				}{{adminID, 50 * gib}, {102, 3 * gib}} {
					t.Run(fmt.Sprintf("%s/%d", app, requester.id), func(t *testing.T) {
						response, err := controller.GetDetailsV2(ctx, requester.id, false, app)
						if err != nil {
							t.Fatalf("GetDetailsV2() error = %v", err)
						}
						if response.Usage != requester.usage {
							t.Errorf("personal Photos usage = %d, want %d", response.Usage, requester.usage)
						}
						if response.FamilyData == nil || len(response.FamilyData.Members) != 3 {
							t.Fatalf("expected two active members and one invitation, got %+v", response.FamilyData)
						}
						for _, member := range response.FamilyData.Members {
							want := map[int64]int64{adminID: 50 * gib, 102: 3 * gib, 103: 0}[member.MemberUserID]
							if member.Usage != want {
								t.Errorf("member %d Photos usage = %d, want %d", member.MemberUserID, member.Usage, want)
							}
						}
					})
				}
			}
		})
	}
}
