package user

import (
	"context"
	"database/sql"
	"testing"
	"time"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/internal/testutil"
	museumcontroller "github.com/ente/museum/pkg/controller"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
)

const (
	familyUsageGiB      int64 = 1 << 30
	familyUsageAdminID  int64 = 401
	familyUsageMemberID int64 = 402
)

func TestFamilyPhotosUsageAndLimits(t *testing.T) {
	for _, tc := range []struct {
		name      string
		locker    int64
		mislinked bool
	}{
		{"Photos only", 0, false},
		{"Photos and Locker", 2 * familyUsageGiB, false},
		{"Photos file linked into Locker", 2 * familyUsageGiB, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, db, ctx, memberID := setupFamilyPhotosUsageTest(t, tc.locker)
			photosUsage := 50 * familyUsageGiB
			if tc.mislinked {
				insertLockerUsageTestLockerFile(t, db, familyUsageMemberID, familyUsageGiB)
				_, err := db.Exec(`UPDATE files SET app='photos' WHERE file_id =
					(SELECT MAX(file_id) FROM files WHERE owner_id=$1)`, familyUsageMemberID)
				require.NoError(t, err)
				_, err = db.Exec("UPDATE usage SET storage_consumed=storage_consumed+$1 WHERE user_id=$2", familyUsageGiB, familyUsageMemberID)
				require.NoError(t, err)
				photosUsage += familyUsageGiB
			}
			family, err := c.FamilyController.FetchMembers(ctx, familyUsageMemberID)
			require.NoError(t, err)
			usage := make(map[int64]int64)
			for _, member := range family.Members {
				usage[member.MemberUserID] = member.Usage
			}
			require.Equal(t, photosUsage, usage[familyUsageMemberID])

			limit := photosUsage - 1
			require.Error(t, c.FamilyController.ModifyMemberStorage(ctx, familyUsageAdminID, memberID, &limit))
			limit = photosUsage
			require.NoError(t, c.FamilyController.ModifyMemberStorage(ctx, familyUsageAdminID, memberID, &limit))
			member, err := c.FamilyController.FamilyRepo.GetMemberById(ctx, memberID)
			require.NoError(t, err)
			require.Equal(t, &limit, member.StorageLimit)

			size := int64(200 << 20)
			limit = photosUsage + size - museumcontroller.StorageOverflowAboveSubscriptionLimit
			require.NoError(t, c.FamilyController.ModifyMemberStorage(ctx, familyUsageAdminID, memberID, &limit))
			uploads := familyPhotosUsageController(c)
			require.NoError(t, uploads.CanUploadFile(ctx, familyUsageMemberID, &size, ente.Photos))
			limit--
			require.NoError(t, c.FamilyController.ModifyMemberStorage(ctx, familyUsageAdminID, memberID, &limit))
			require.ErrorIs(t, uploads.CanUploadFile(ctx, familyUsageMemberID, &size, ente.Photos), ente.ErrStorageLimitExceeded)
		})
	}
}

func TestConcurrentLockerGrowthKeepsPhotosUsageConsistent(t *testing.T) {
	c, db, _, memberID := setupFamilyPhotosUsageTest(t, 2*familyUsageGiB)
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	limit := int64(50 * familyUsageGiB)
	require.NoError(t, c.FamilyController.ModifyMemberStorage(ctx, familyUsageAdminID, memberID, &limit))
	growth, err := db.BeginTx(ctx, nil)
	require.NoError(t, err)
	defer growth.Rollback()
	_, err = growth.ExecContext(ctx, "LOCK TABLE object_keys IN ACCESS EXCLUSIVE MODE")
	require.NoError(t, err)
	var blocker int
	require.NoError(t, growth.QueryRowContext(ctx, "SELECT pg_backend_pid()").Scan(&blocker))
	done := make(chan error, 1)
	go func() {
		size := int64(200 << 20)
		done <- familyPhotosUsageController(c).CanUploadFile(ctx, familyUsageMemberID, &size, ente.Photos)
	}()
	for {
		var waiting bool
		require.NoError(t, db.QueryRowContext(ctx, `SELECT EXISTS (
			SELECT 1 FROM pg_stat_activity WHERE datname = current_database()
			AND $1 = ANY(pg_blocking_pids(pid)))`, blocker).Scan(&waiting))
		if waiting {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	_, err = growth.ExecContext(ctx, `UPDATE object_keys SET size=size+$1
		WHERE file_id IN (SELECT file_id FROM files WHERE owner_id=$2)`, familyUsageGiB, familyUsageMemberID)
	require.NoError(t, err)
	_, err = growth.ExecContext(ctx, "UPDATE usage SET storage_consumed=storage_consumed+$1 WHERE user_id=$2", familyUsageGiB, familyUsageMemberID)
	require.NoError(t, err)
	require.NoError(t, growth.Commit())
	require.ErrorIs(t, <-done, ente.ErrStorageLimitExceeded)
}

func setupFamilyPhotosUsageTest(t *testing.T, lockerBytes int64) (*UserController, *sql.DB, *gin.Context, uuid.UUID) {
	t.Helper()
	c, db, ctx := setupLockerUsageControllerTest(t)
	adminID := familyUsageAdminID
	for _, member := range []struct {
		id     int64
		status ente.MemberStatus
		photos int64
		locker int64
	}{
		{adminID, ente.SELF, 5 * familyUsageGiB, 0},
		{familyUsageMemberID, ente.ACCEPTED, 50 * familyUsageGiB, lockerBytes},
	} {
		insertLockerUsageTestUser(t, db, member.id, &adminID)
		insertLockerUsageTestFamilyMember(t, db, adminID, member.id, member.status)
		testutil.InsertUsage(t, db, member.id, member.photos+member.locker)
		if member.locker > 0 {
			insertLockerUsageTestLockerFile(t, db, member.id, member.locker)
		}
		testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{
			UserID: member.id, Storage: 100 * familyUsageGiB,
			ExpiryTime: time.Now().Add(24 * time.Hour).UnixMicro(), ProductID: ente.FamilyPlanProductID,
		})
	}
	var memberID uuid.UUID
	require.NoError(t, db.QueryRow("UPDATE families SET storage_limit=$1 WHERE member_id=$2 RETURNING id", 80*familyUsageGiB, familyUsageMemberID).Scan(&memberID))
	return c, db, ctx, memberID
}

func familyPhotosUsageController(c *UserController) *museumcontroller.UsageController {
	return &museumcontroller.UsageController{
		BillingCtrl: c.BillingController, UserCacheCtrl: c.UserCacheController,
		UsageRepo: c.UsageRepo, UserRepo: c.UserRepo, FamilyRepo: c.FamilyController.FamilyRepo,
		UploadResultCache: make(map[int64]bool),
	}
}
