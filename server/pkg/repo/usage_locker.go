package repo

import (
	"context"
	"database/sql"

	"github.com/ente/stacktrace"
	"github.com/lib/pq"
)

// Deleted memberships still identify charged Locker files until their objects are deleted.
const lockerFilesQuery = `SELECT DISTINCT c.owner_id, cf.file_id
	FROM collections AS c
	JOIN collection_files AS cf ON cf.collection_id = c.collection_id
	WHERE c.app = 'locker' AND c.owner_id = ANY($1) AND cf.f_owner_id = c.owner_id`

func applyFileStorageChange(ctx context.Context, tx *sql.Tx, userID, fileID, delta int64) (int64, error) {
	change := usageChange{StorageDelta: delta}
	if delta != 0 {
		var locker bool
		err := tx.QueryRowContext(ctx, `SELECT EXISTS (`+lockerFilesQuery+` AND cf.file_id = $2)`,
			pq.Array([]int64{userID}), fileID).Scan(&locker)
		if err != nil {
			return 0, stacktrace.Propagate(err, "failed to identify Locker storage")
		}
		if locker {
			change.LockerStorageDelta = delta
		}
	}
	return applyUsageChange(ctx, tx, userID, change)
}

func lockerStorageForFiles(ctx context.Context, tx *sql.Tx, userID int64, fileIDs []int64) (int64, error) {
	var bytes int64
	err := tx.QueryRowContext(ctx, `WITH locker_files AS (`+lockerFilesQuery+` AND cf.file_id = ANY($2))
		SELECT COALESCE(SUM(ok.size), 0)
		FROM locker_files AS lf
		JOIN object_keys AS ok ON ok.file_id = lf.file_id AND ok.is_deleted = FALSE`,
		pq.Array([]int64{userID}), pq.Array(fileIDs)).Scan(&bytes)
	return bytes, stacktrace.Propagate(err, "failed to calculate Locker storage")
}

func newLockerMembershipBytes(ctx context.Context, tx *sql.Tx, userID, collectionID int64, fileIDs []int64) (int64, error) {
	var bytes int64
	err := tx.QueryRowContext(ctx, `WITH locker_files AS (`+lockerFilesQuery+` AND cf.file_id = ANY($3))
		SELECT CASE WHEN c.app = 'locker' AND c.owner_id = ANY($1) THEN (
			SELECT COALESCE(SUM(ok.size), 0) FROM object_keys AS ok
			WHERE ok.file_id = ANY($3) AND ok.is_deleted = FALSE
				AND NOT EXISTS (SELECT 1 FROM locker_files AS lf WHERE lf.file_id = ok.file_id)
				AND NOT EXISTS (
					SELECT 1 FROM collection_files AS cf
					WHERE cf.collection_id = $2 AND cf.file_id = ok.file_id
						AND cf.f_owner_id IS DISTINCT FROM c.owner_id
				)
		) ELSE 0 END
		FROM collections AS c WHERE c.collection_id = $2`,
		pq.Array([]int64{userID}), collectionID, pq.Array(fileIDs)).Scan(&bytes)
	return bytes, stacktrace.Propagate(err, "failed to calculate new Locker membership storage")
}
