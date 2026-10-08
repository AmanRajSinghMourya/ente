package repo

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/ente/storagebonus"
	"github.com/ente/museum/pkg/utils/crypto"
	"github.com/ente/museum/pkg/utils/time"
)

const (
	PhotosStorageWarningTemplateID  = "photos_storage_90_percent"
	PhotosStorageReminderTemplateID = "photos_storage_reminder"
)

type PhotosStorageState struct {
	User             ente.User
	Usage, Allowance int64
	Eligible         bool
}

func (repo *UsageRepository) GetPhotosStorageWarningCandidates(ctx context.Context, launchTime int64) ([]int64, error) {
	rows, err := repo.DB.QueryContext(ctx, `
  SELECT u.user_id
  FROM users u
  JOIN subscriptions s ON s.user_id = u.user_id
  JOIN usage us ON us.user_id = u.user_id
  WHERE u.creation_time >= $1
    AND u.family_admin_id IS NULL
    AND u.encrypted_email IS NOT NULL
    AND s.product_id = $2
    AND s.storage > 0
    AND s.expiry_time > now_utc_micro_seconds()
    AND us.storage_consumed >= s.storage - s.storage / 10
    AND NOT EXISTS (
      SELECT 1 FROM notification_history n
      WHERE n.user_id = u.user_id AND n.template_id = $3
    )
  ORDER BY u.user_id`, launchTime, ente.FreePlanProductID, PhotosStorageReminderTemplateID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func (repo *NotificationHistoryRepository) BeginStorageNotification(ctx context.Context, userID int64) (*sql.Tx, error) {
	tx, err := repo.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	var id int64
	if err := tx.QueryRowContext(ctx, `SELECT user_id FROM users WHERE user_id=$1 FOR NO KEY UPDATE`, userID).Scan(&id); err != nil {
		_ = tx.Rollback()
		return nil, err
	}
	return tx, nil
}

func PhotosStorageHistory(ctx context.Context, tx *sql.Tx, userID int64) (map[string]int64, error) {
	rows, err := tx.QueryContext(ctx, `
  SELECT template_id, MAX(sent_time)
  FROM notification_history
  WHERE user_id=$1 AND template_id IN ($2,$3,$4,$5,$6)
  GROUP BY template_id`, userID, PhotosStorageWarningTemplateID, PhotosStorageReminderTemplateID,
		StorageWarningExpiredScheduledDeletionTemplateID, StorageWarningActiveOverageScheduledDeletionTemplateID, StorageWarningLoginGraceTemplateID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	history := make(map[string]int64)
	for rows.Next() {
		var event string
		var at int64
		if err := rows.Scan(&event, &at); err != nil {
			return nil, err
		}
		history[event] = at
	}
	return history, rows.Err()
}

func ClaimStorageNotification(ctx context.Context, tx *sql.Tx, userID int64, event string) (bool, error) {
	result, err := tx.ExecContext(ctx, `
  INSERT INTO notification_history(user_id,template_id,sent_time) VALUES($1,$2,$3)
  ON CONFLICT(user_id,template_id) WHERE left(template_id,15)='photos_storage_' DO NOTHING`, userID, event, time.Microseconds())
	if err != nil {
		return false, err
	}
	count, err := result.RowsAffected()
	return count == 1, err
}

func (repo *UserRepository) PhotosStorageState(ctx context.Context, tx *sql.Tx, userID int64) (PhotosStorageState, error) {
	var state PhotosStorageState
	var subscription ente.Subscription
	var encrypted, nonce, bonusesJSON []byte
	var totalUsage, lockerUsage int64
	now := time.Microseconds()
	err := tx.QueryRowContext(ctx, `
  SELECT u.user_id, u.encrypted_email, u.email_decryption_nonce, u.family_admin_id, u.creation_time,
    s.product_id, s.storage, s.expiry_time, COALESCE(us.storage_consumed,0),
    (SELECT COALESCE(json_agg(json_build_object('type',type,'storage',storage)), '[]')
     FROM storage_bonus
     WHERE user_id=$1 AND NOT is_revoked AND (valid_till=0 OR valid_till>$2)),
    (SELECT COALESCE(SUM(ok.size),0)
     FROM (
       SELECT DISTINCT cf.file_id
       FROM collections c JOIN collection_files cf ON cf.collection_id=c.collection_id
       WHERE c.owner_id=$1 AND c.app='locker' AND cf.f_owner_id=c.owner_id
     ) locker
     JOIN object_keys ok ON ok.file_id=locker.file_id AND NOT ok.is_deleted)
  FROM users u
  JOIN subscriptions s ON s.user_id=u.user_id
  LEFT JOIN usage us ON us.user_id=u.user_id
  WHERE u.user_id=$1`, userID, now).Scan(
		&state.User.ID, &encrypted, &nonce, &state.User.FamilyAdminID, &state.User.CreationTime,
		&subscription.ProductID, &subscription.Storage, &subscription.ExpiryTime, &totalUsage, &bonusesJSON, &lockerUsage)
	if err != nil {
		return state, err
	}
	if len(encrypted) == 0 {
		return state, nil
	}
	state.User.Email, err = crypto.Decrypt(encrypted, repo.SecretEncryptionKey, nonce)
	if err != nil {
		return state, err
	}
	var bonuses storagebonus.ActiveStorageBonus
	if err := json.Unmarshal(bonusesJSON, &bonuses.StorageBonuses); err != nil {
		return state, err
	}
	state.Usage = totalUsage - lockerUsage
	state.Allowance = subscription.Storage + bonuses.GetUsableBonus(subscription.Storage)
	state.Eligible = state.User.Email != "" && state.User.FamilyAdminID == nil &&
		subscription.ProductID == ente.FreePlanProductID && bonuses.GetAddonStorage() == 0 &&
		subscription.ExpiryTime > now && state.Allowance > 0 && state.Usage >= state.Allowance-state.Allowance/10
	return state, nil
}
