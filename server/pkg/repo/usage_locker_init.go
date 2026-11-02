package repo

import (
	"context"
	"database/sql"
	"errors"

	"github.com/lib/pq"
)

var ErrLockerUsageIneligible = errors.New("Locker membership and file ownership disagree")

func (repo *UsageRepository) InitializeLockerUsage(ctx context.Context, userID int64) (bool, error) {
	snapshot, err := repo.readLockerUsageSnapshot(ctx, userID)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !snapshot.eligible {
		return false, ErrLockerUsageIneligible
	}
	return repo.publishInitialLockerUsage(ctx, userID, snapshot)
}

func (repo *UsageRepository) GetLockerUsageInitializationCandidates(ctx context.Context, afterUserID int64, limit int) ([]int64, error) {
	rows, err := repo.DB.QueryContext(ctx, `SELECT user_id
		FROM usage
		WHERE user_id > $1
			AND locker_usage IS NULL
		ORDER BY user_id
		LIMIT $2`, afterUserID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var userIDs []int64
	for rows.Next() {
		var userID int64
		if err := rows.Scan(&userID); err != nil {
			return nil, err
		}
		userIDs = append(userIDs, userID)
	}
	return userIDs, rows.Err()
}

type lockerUsageSnapshot struct {
	bytes, version int64
	eligible       bool
}

func (repo *UsageRepository) readLockerUsageSnapshot(ctx context.Context, userID int64) (lockerUsageSnapshot, error) {
	var snapshot lockerUsageSnapshot
	err := repo.DB.QueryRowContext(ctx, `WITH locker_files AS MATERIALIZED (
			SELECT DISTINCT c.owner_id, cf.file_id
			FROM collections AS c
			JOIN collection_files AS cf ON cf.collection_id = c.collection_id
			WHERE c.app = 'locker'
				AND c.owner_id = ANY($1)
				AND cf.f_owner_id = c.owner_id
		)
		SELECT u.file_count_source_version,
			(
				SELECT COALESCE(SUM(ok.size), 0)
				FROM locker_files AS lf
				JOIN object_keys AS ok ON ok.file_id = lf.file_id AND ok.is_deleted = FALSE
			),
			NOT EXISTS (
				SELECT 1 FROM locker_files AS lf
				LEFT JOIN files AS f ON f.file_id = lf.file_id
				WHERE f.owner_id IS DISTINCT FROM lf.owner_id
			)
		FROM usage AS u
		WHERE u.user_id = $2
			AND u.locker_usage IS NULL`,
		pq.Array([]int64{userID}), userID).Scan(&snapshot.version, &snapshot.bytes, &snapshot.eligible)
	return snapshot, err
}

func (repo *UsageRepository) publishInitialLockerUsage(ctx context.Context, userID int64, snapshot lockerUsageSnapshot) (bool, error) {
	result, err := repo.DB.ExecContext(ctx, `UPDATE usage
		SET locker_usage = $2
		WHERE user_id = $1
			AND locker_usage IS NULL
			AND file_count_source_version = $3`,
		userID, snapshot.bytes, snapshot.version)
	if err != nil {
		return false, err
	}
	updated, err := result.RowsAffected()
	return updated == 1, err
}
