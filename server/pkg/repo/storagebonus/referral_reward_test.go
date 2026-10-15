package storagebonus

import (
	"fmt"
	entity "github.com/ente/museum/ente/storagebonus"
	"github.com/ente/museum/internal/testutil"
	"github.com/stretchr/testify/require"
	"testing"
)

func TestReferralUpgradeRejectsAlreadyCreditedReward(t *testing.T) {
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	for _, id := range []int64{1, 2} {
		testutil.InsertUser(t, db, testutil.UserFixture{UserID: id, Email: fmt.Sprintf("u%d@example.com", id), CreationTime: 1})
	}
	r := NewRepository(db)
	require.NoError(t, r.TrackReferralAndInviteeBonus(t.Context(), 1, 2, entity.TenGbOnUpgrade))
	require.NoError(t, r.TrackUpgradeAndInvitorBonus(t.Context(), 1, 2, entity.TenGbOnUpgrade))
	require.Error(t, r.TrackUpgradeAndInvitorBonus(t.Context(), 1, 2, entity.TenGbOnUpgrade))
}
