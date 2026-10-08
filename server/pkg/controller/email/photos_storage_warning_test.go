package email

import (
	"bytes"
	"database/sql"
	"errors"
	"fmt"
	"html/template"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	stdtime "time"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/internal/testutil"
	"github.com/ente/museum/pkg/repo"
	"github.com/ente/museum/pkg/utils/time"
	"github.com/spf13/viper"
)

const storageEmailCutoff = int64(1767225600000000)

func setupStorageEmailTest(t *testing.T, usage int64) (*EmailNotificationController, *sql.DB, *[]string) {
	t.Helper()
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	testutil.InsertUser(t, db, testutil.UserFixture{UserID: 1, Email: "storage@ente.com", CreationTime: storageEmailCutoff})
	testutil.InsertUsage(t, db, 1, usage)
	testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{UserID: 1, Storage: 1000, ProductID: ente.FreePlanProductID, ExpiryTime: time.MicrosecondsAfterHours(24)})
	c := newStorageWarningIntegrationController(db)
	c.UserRepo.StorageBonusRepo = c.StorageBonusRepo
	oldLaunch := viper.Get("photos-storage-emails.launch-time")
	oldSend := sendPhotosStorageWarningEmail
	viper.Set("photos-storage-emails.launch-time", "2026-01-01T00:00:00Z")
	t.Cleanup(func() {
		viper.Set("photos-storage-emails.launch-time", oldLaunch)
		sendPhotosStorageWarningEmail = oldSend
	})
	attempts := []string{}
	sendPhotosStorageWarningEmail = func(to []string, _, _, subject, _, name string, data map[string]interface{}, _ []map[string]interface{}) error {
		if len(to) != 1 || to[0] != "storage@ente.com" {
			t.Fatalf("recipients=%v", to)
		}
		wantSubject := "Your Ente Photos storage is almost full"
		if data["Full"] == true {
			wantSubject = "Your Ente Photos storage is full"
		}
		if subject != wantSubject {
			t.Fatalf("subject=%q", subject)
		}
		event := repo.PhotosStorageWarningTemplateID
		if name == "photos_storage_reminder.html" {
			event = repo.PhotosStorageReminderTemplateID
		}
		assertStorageWarningNotificationCount(t, db, 1, event, 1)
		attempts = append(attempts, name)
		return nil
	}
	return c, db, &attempts
}

func storageEmailSQL(t *testing.T, db *sql.DB, query string, args ...interface{}) {
	t.Helper()
	if _, err := db.Exec(query, args...); err != nil {
		t.Fatal(err)
	}
}

func ageStorageEmail(t *testing.T, db *sql.DB, hours int64) int64 {
	t.Helper()
	at := time.Microseconds() - hours*time.MicroSecondsInOneHour
	storageEmailSQL(t, db, `UPDATE notification_history SET sent_time=$1 WHERE user_id=1 AND template_id=$2`, at, repo.PhotosStorageWarningTemplateID)
	return at
}

func TestPhotosStorageEligibility(t *testing.T) {
	for _, tc := range []struct {
		name  string
		usage int64
		setup string
		want  int
	}{
		{"below", 899, "", 0}, {"at threshold", 900, "", 1}, {"full", 1000, "", 1}, {"over full", 1100, "", 1},
		{"fraction below", 900, `UPDATE subscriptions SET storage=1001`, 0}, {"fraction above", 901, `UPDATE subscriptions SET storage=1001`, 1},
		{"referral", 950, `INSERT INTO storage_bonus(bonus_id,user_id,type,storage) VALUES('b',1,'REFERRAL',1000)`, 0},
		{"capped signup", 1800, `INSERT INTO storage_bonus(bonus_id,user_id,type,storage) VALUES('b',1,'SIGN_UP',3000)`, 1},
		{"expired bonus", 900, `INSERT INTO storage_bonus(bonus_id,user_id,type,storage,valid_till) VALUES('b',1,'SIGN_UP',1000,1)`, 1},
		{"revoked addon", 900, `INSERT INTO storage_bonus(bonus_id,user_id,type,storage,is_revoked) VALUES('b',1,'ADD_ON_SUPPORT',1000,true)`, 1},
		{"expired addon", 900, `INSERT INTO storage_bonus(bonus_id,user_id,type,storage,valid_till) VALUES('b',1,'ADD_ON_SUPPORT',1000,1)`, 1},
		{"paid addon", 1800, `INSERT INTO storage_bonus(bonus_id,user_id,type,storage) VALUES('b',1,'ADD_ON_SUPPORT',1000)`, 0},
		{"paid", 950, `UPDATE subscriptions SET product_id='paid'`, 0}, {"family", 950, `UPDATE users SET family_admin_id=1`, 0},
		{"expired", 950, `UPDATE subscriptions SET expiry_time=1`, 0}, {"no allowance", 950, `UPDATE subscriptions SET storage=0`, 0},
		{"missing email", 950, `UPDATE users SET encrypted_email=NULL`, 0},
		{"legacy history", 950, `INSERT INTO notification_history(user_id,template_id,sent_time) VALUES(1,'storage_limit_exceeded',1)`, 1},
		{"before launch", 950, `UPDATE users SET creation_time=1767225599999999`, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, db, attempts := setupStorageEmailTest(t, tc.usage)
			if tc.setup != "" {
				storageEmailSQL(t, db, tc.setup)
			}
			c.SendPhotosStorageWarningMails()
			c.SendPhotosStorageWarningMails()
			if len(*attempts) != tc.want {
				t.Fatalf("attempts=%v want=%d", *attempts, tc.want)
			}
			assertStorageWarningNotificationCount(t, db, 1, repo.PhotosStorageWarningTemplateID, tc.want)
		})
	}
}

func TestPhotosStorageReminderPausesAndResumes(t *testing.T) {
	for _, pause := range []string{`UPDATE usage SET storage_consumed=850`, `UPDATE subscriptions SET product_id='paid'`} {
		t.Run(pause, func(t *testing.T) {
			c, db, attempts := setupStorageEmailTest(t, 900)
			c.SendPhotosStorageWarningMails()
			first := ageStorageEmail(t, db, 24)
			storageEmailSQL(t, db, pause)
			c.SendPhotosStorageWarningMails()
			var count int
			if err := db.QueryRow(`SELECT count(*) FROM notification_history WHERE user_id=1 AND left(template_id,15)='photos_storage_'`).Scan(&count); err != nil {
				t.Fatal(err)
			}
			if count != 1 {
				t.Fatalf("paused flow wrote %d events, want 1", count)
			}
			storageEmailSQL(t, db, `UPDATE usage SET storage_consumed=900`)
			storageEmailSQL(t, db, `UPDATE subscriptions SET product_id='free'`)
			c.SendPhotosStorageWarningMails()
			var stored int64
			if err := db.QueryRow(`SELECT sent_time FROM notification_history WHERE user_id=1 AND template_id=$1`, repo.PhotosStorageWarningTemplateID).Scan(&stored); err != nil {
				t.Fatal(err)
			}
			if stored != first || len(*attempts) != 1 {
				t.Fatalf("clock reset or early reminder: stored=%d first=%d attempts=%v", stored, first, *attempts)
			}
			ageStorageEmail(t, db, 72)
			restarted := newStorageWarningIntegrationController(db)
			restarted.SendPhotosStorageWarningMails()
			restarted.SendPhotosStorageWarningMails()
			if fmt.Sprint(*attempts) != "[photos_storage_warning.html photos_storage_reminder.html]" {
				t.Fatalf("attempts=%v", *attempts)
			}
		})
	}
}

func TestPhotosStorageReminderTimingAndCutoff(t *testing.T) {
	for _, tc := range []struct {
		name  string
		hours int64
		setup string
		want  int
	}{
		{"47 hours", 47, "", 0}, {"48 hours", 48, "", 1}, {"weeks later", 24 * 21, "", 1},
		{"legacy warning", 72, `INSERT INTO notification_history(user_id,template_id,sent_time) VALUES(1,'storage_limit_exceeded',1)`, 1},
		{"prelaunch E1", 72, `UPDATE users SET creation_time=1767225599999999`, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, db, attempts := setupStorageEmailTest(t, 900)
			testutil.InsertNotificationHistory(t, db, testutil.NotificationHistoryFixture{UserID: 1, TemplateID: repo.PhotosStorageWarningTemplateID, SentTime: time.Microseconds() - tc.hours*time.MicroSecondsInOneHour})
			if tc.setup != "" {
				storageEmailSQL(t, db, tc.setup)
			}
			c.SendPhotosStorageWarningMails()
			c.SendPhotosStorageWarningMails()
			if len(*attempts) != tc.want {
				t.Fatalf("attempts=%v want=%d", *attempts, tc.want)
			}
		})
	}
}

func TestPhotosStorageFinalEligibilityCheck(t *testing.T) {
	for _, change := range []string{`UPDATE users SET creation_time=1767225599999999`, `UPDATE subscriptions SET product_id='paid'`, `UPDATE usage SET storage_consumed=850`} {
		t.Run(change, func(t *testing.T) {
			c, db, _ := setupStorageEmailTest(t, 900)
			ids, err := c.UsageRepo.GetPhotosStorageWarningCandidates(t.Context(), storageEmailCutoff)
			if err != nil || len(ids) != 1 {
				t.Fatalf("ids=%v err=%v", ids, err)
			}
			storageEmailSQL(t, db, change)
			_, event, err := c.preparePhotosStorageEmail(t.Context(), 1, storageEmailCutoff)
			if err != nil || event != "" {
				t.Fatalf("event=%q err=%v", event, err)
			}
			assertStorageWarningNotificationCount(t, db, 1, repo.PhotosStorageWarningTemplateID, 0)
		})
	}
}

func TestPhotosStorageConcurrentPreparation(t *testing.T) {
	for _, reminder := range []bool{false, true} {
		t.Run(fmt.Sprint(reminder), func(t *testing.T) {
			c, db, _ := setupStorageEmailTest(t, 900)
			event := repo.PhotosStorageWarningTemplateID
			if reminder {
				event = repo.PhotosStorageReminderTemplateID
				testutil.InsertNotificationHistory(t, db, testutil.NotificationHistoryFixture{UserID: 1, TemplateID: repo.PhotosStorageWarningTemplateID, SentTime: time.Microseconds() - 72*time.MicroSecondsInOneHour})
			}
			var workers sync.WaitGroup
			var claims atomic.Int32
			for range 10 {
				workers.Go(func() {
					_, claimed, err := c.preparePhotosStorageEmail(t.Context(), 1, storageEmailCutoff)
					if err != nil {
						t.Error(err)
					}
					if claimed == event {
						claims.Add(1)
					}
				})
			}
			workers.Wait()
			if claims.Load() != 1 {
				t.Fatalf("claims=%d", claims.Load())
			}
			assertStorageWarningNotificationCount(t, db, 1, event, 1)
		})
	}
}

func TestPhotosStorageFailedAttemptsAreConsumed(t *testing.T) {
	for _, reminder := range []bool{false, true} {
		t.Run(fmt.Sprint(reminder), func(t *testing.T) {
			c, db, _ := setupStorageEmailTest(t, 900)
			event := repo.PhotosStorageWarningTemplateID
			if reminder {
				event = repo.PhotosStorageReminderTemplateID
				testutil.InsertNotificationHistory(t, db, testutil.NotificationHistoryFixture{UserID: 1, TemplateID: repo.PhotosStorageWarningTemplateID, SentTime: time.Microseconds() - 72*time.MicroSecondsInOneHour})
			}
			attempts := 0
			sendPhotosStorageWarningEmail = func(_ []string, _, _, _, _, _ string, _ map[string]interface{}, _ []map[string]interface{}) error {
				attempts++
				assertStorageWarningNotificationCount(t, db, 1, event, 1)
				return errors.New("SMTP failed")
			}
			c.SendPhotosStorageWarningMails()
			newStorageWarningIntegrationController(db).SendPhotosStorageWarningMails()
			if attempts != 1 {
				t.Fatalf("attempts=%d", attempts)
			}
		})
	}
}

func TestPhotosStorageRestrictedAccounts(t *testing.T) {
	for _, terminal := range repo.StorageWarningScheduledDeletionTemplateIDs() {
		for _, grace := range []int64{0, 1, 169} {
			t.Run(fmt.Sprintf("%s/%d", terminal, grace), func(t *testing.T) {
				c, db, attempts := setupStorageEmailTest(t, 900)
				testutil.InsertNotificationHistory(t, db, testutil.NotificationHistoryFixture{UserID: 1, TemplateID: terminal, SentTime: time.Microseconds()})
				if grace > 0 {
					testutil.InsertNotificationHistory(t, db, testutil.NotificationHistoryFixture{UserID: 1, TemplateID: repo.StorageWarningLoginGraceTemplateID, SentTime: time.Microseconds() - grace*time.MicroSecondsInOneHour})
				}
				c.SendPhotosStorageWarningMails()
				want := 0
				if grace == 1 {
					want = 1
				}
				if len(*attempts) != want {
					t.Fatalf("attempts=%v want=%d", *attempts, want)
				}
			})
		}
	}
}

func TestPhotosStorageGraceWithoutTerminalRows(t *testing.T) {
	for _, reminder := range []bool{false, true} {
		for _, expired := range []bool{false, true} {
			t.Run(fmt.Sprintf("reminder=%t/expired=%t", reminder, expired), func(t *testing.T) {
				c, db, attempts := setupStorageEmailTest(t, 900)
				event := repo.PhotosStorageWarningTemplateID
				first := time.Microseconds() - 72*time.MicroSecondsInOneHour
				if reminder {
					event = repo.PhotosStorageReminderTemplateID
					testutil.InsertNotificationHistory(t, db, testutil.NotificationHistoryFixture{UserID: 1, TemplateID: repo.PhotosStorageWarningTemplateID, SentTime: first})
				}
				testutil.InsertNotificationHistory(t, db, testutil.NotificationHistoryFixture{UserID: 1, TemplateID: repo.StorageWarningActiveOverageScheduledDeletionTemplateID, SentTime: time.Microseconds()})
				if _, granted, err := c.NotificationHistoryRepo.GrantStorageWarningLoginGrace(1); err != nil || !granted {
					t.Fatalf("grant grace: granted=%t err=%v", granted, err)
				}
				assertStorageWarningNotificationCount(t, db, 1, repo.StorageWarningActiveOverageScheduledDeletionTemplateID, 0)
				if expired {
					storageEmailSQL(t, db, `UPDATE notification_history SET sent_time=$1 WHERE user_id=1 AND template_id=$2`, time.Microseconds()-repo.StorageWarningLoginGraceDurationMicroseconds-1, repo.StorageWarningLoginGraceTemplateID)
				}
				c.SendPhotosStorageWarningMails()
				want := 1
				if expired {
					want = 0
				}
				if len(*attempts) != want {
					t.Fatalf("attempts=%v want=%d", *attempts, want)
				}
				assertStorageWarningNotificationCount(t, db, 1, event, want)
				if err := c.NotificationHistoryRepo.ClearStorageWarningLoginGrace(1); err != nil {
					t.Fatal(err)
				}
				c.SendPhotosStorageWarningMails()
				c.SendPhotosStorageWarningMails()
				if len(*attempts) != 1 {
					t.Fatalf("resumed attempts=%v want=1", *attempts)
				}
				assertStorageWarningNotificationCount(t, db, 1, event, 1)
				if reminder {
					stored, err := c.NotificationHistoryRepo.GetLastNotificationTime(1, repo.PhotosStorageWarningTemplateID)
					if err != nil || stored != first {
						t.Fatalf("E1 timestamp=%d want=%d err=%v", stored, first, err)
					}
				}
			})
		}
	}
}

func TestPhotosStorageLaunchConfiguration(t *testing.T) {
	for _, value := range []string{"", "invalid", "1767225600", "2026-01-01T00:00:00+05:30"} {
		t.Run(value, func(t *testing.T) {
			c, db, attempts := setupStorageEmailTest(t, 900)
			viper.Set("photos-storage-emails.launch-time", value)
			c.SendPhotosStorageWarningMails()
			if len(*attempts) != 0 {
				t.Fatalf("invalid launch sent %v", *attempts)
			}
			assertStorageWarningNotificationCount(t, db, 1, repo.PhotosStorageWarningTemplateID, 0)
		})
	}
}

func TestPhotosStorageBonusExpiryAfterLockWait(t *testing.T) {
	c, db, _ := setupStorageEmailTest(t, 900)
	locked, err := c.NotificationHistoryRepo.BeginStorageNotification(t.Context(), 1)
	if err != nil {
		t.Fatal(err)
	}
	defer locked.Rollback()
	expiry := stdtime.Now().Add(300 * stdtime.Millisecond)
	storageEmailSQL(t, db, `INSERT INTO storage_bonus(bonus_id,user_id,type,storage,valid_till) VALUES('b',1,'REFERRAL',1000,$1)`, expiry.UnixMicro())
	result := make(chan string, 1)
	fail := make(chan error, 1)
	go func() {
		_, event, err := c.preparePhotosStorageEmail(t.Context(), 1, storageEmailCutoff)
		if err != nil {
			fail <- err
		} else {
			result <- event
		}
	}()
	stdtime.Sleep(stdtime.Until(expiry) + 10*stdtime.Millisecond)
	if err := locked.Commit(); err != nil {
		t.Fatal(err)
	}
	select {
	case event := <-result:
		if event != repo.PhotosStorageWarningTemplateID {
			t.Fatalf("event=%q", event)
		}
	case err := <-fail:
		t.Fatal(err)
	case <-stdtime.After(5 * stdtime.Second):
		t.Fatal("lock wait timed out")
	}
}

func TestStorageMailersSeparateAudiences(t *testing.T) {
	for _, tc := range []struct {
		name, setup    string
		usage          int64
		photos, legacy int
	}{
		{"free", "", 1100, 1, 0},
		{"paid before cutoff", `UPDATE subscriptions SET product_id='paid'; UPDATE users SET creation_time=1`, 1100, 0, 1},
		{"paid addon", `INSERT INTO storage_bonus(bonus_id,user_id,type,storage) VALUES('b',1,'ADD_ON_SUPPORT',1000)`, 2001, 0, 1},
		{"paid exactly full", `UPDATE subscriptions SET product_id='paid'`, 1000, 0, 0},
		{"free with signup", `INSERT INTO storage_bonus(bonus_id,user_id,type,storage) VALUES('b',1,'SIGN_UP',3000)`, 2200, 1, 0},
		{"family admin free", "", 1100, 0, 0},
		{"family member free", "", 1100, 0, 0},
		{"family admin paid", `UPDATE subscriptions SET product_id='paid'`, 1100, 0, 0},
		{"family member paid", `UPDATE subscriptions SET product_id='paid'`, 1100, 0, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, db, attempts := setupStorageEmailTest(t, tc.usage)
			if strings.HasPrefix(tc.name, "family ") {
				adminID := int64(1)
				if strings.HasPrefix(tc.name, "family member ") {
					adminID = 2
					testutil.InsertUser(t, db, testutil.UserFixture{UserID: adminID, Email: "admin@ente.com", CreationTime: storageEmailCutoff})
				}
				family := &repo.FamilyRepository{DB: db}
				if err := family.CreateFamily(t.Context(), adminID); err != nil {
					t.Fatal(err)
				}
				if adminID != 1 {
					token, err := family.AddMemberInvite(t.Context(), adminID, 1, "storage-email-family-test", nil)
					if err != nil {
						t.Fatal(err)
					}
					if err := family.AcceptInvite(t.Context(), adminID, 1, token); err != nil {
						t.Fatal(err)
					}
				}
			}
			if tc.setup != "" {
				storageEmailSQL(t, db, tc.setup)
			}
			old := sendStorageLimitExceededEmail
			t.Cleanup(func() { sendStorageLimitExceededEmail = old })
			legacy := 0
			sendStorageLimitExceededEmail = func(_ []string, _, _, _, _ string, _ map[string]interface{}, _ []map[string]interface{}) error {
				legacy++
				return nil
			}
			c.SendStorageLimitExceededMails()
			c.SendPhotosStorageWarningMails()
			c.SendStorageLimitExceededMails()
			if legacy != tc.legacy || len(*attempts) != tc.photos {
				t.Fatalf("photos=%v legacy=%d want=%d/%d", *attempts, legacy, tc.photos, tc.legacy)
			}
		})
	}
}

func TestPhotosStorageExcludesLockerTrash(t *testing.T) {
	c, db, attempts := setupStorageEmailTest(t, 950)
	storageEmailSQL(t, db, `
 WITH f AS (
  INSERT INTO files(owner_id,file_decryption_header,thumbnail_decryption_header,metadata_decryption_header,encrypted_metadata,updation_time,info)
  VALUES(1,'h','h','h','m',1,'{}') RETURNING file_id
 ), c AS (
  INSERT INTO collections(owner_id,encrypted_key,key_decryption_nonce,name,type,attributes,updation_time,app)
  VALUES(1,'k','n','Locker','album','{}',1,'locker') RETURNING collection_id
 ), o AS (
  INSERT INTO object_keys(file_id,o_type,object_key,size,datacenters)
  SELECT file_id,'file','locker-object',100,'{b2-eu-cen}' FROM f
 )
 INSERT INTO collection_files(collection_id,file_id,encrypted_key,key_decryption_nonce,updation_time,c_owner_id,f_owner_id,is_deleted)
 SELECT collection_id,file_id,'k','n',1,1,1,true FROM f,c`)
	c.SendPhotosStorageWarningMails()
	if len(*attempts) != 0 {
		t.Fatalf("85%% Photos usage sent %v", *attempts)
	}
	storageEmailSQL(t, db, `UPDATE usage SET storage_consumed=1000`)
	sendPhotosStorageWarningEmail = func(_ []string, _, _, _, _, _ string, data map[string]interface{}, _ []map[string]interface{}) error {
		if data["UsagePercent"] != "90.0" || data["Full"] != false {
			t.Fatalf("data=%v", data)
		}
		*attempts = append(*attempts, "email")
		return nil
	}
	c.SendPhotosStorageWarningMails()
	if len(*attempts) != 1 {
		t.Fatalf("90%% Photos usage attempts=%v", *attempts)
	}
}

func TestPhotosStorageTemplates(t *testing.T) {
	for _, name := range []string{"photos_storage_warning.html", "photos_storage_reminder.html"} {
		for _, full := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/%t", name, full), func(t *testing.T) {
				testutil.WithServerRoot(t)
				tpl, err := template.ParseFiles("mail-templates/ente_base.html", "mail-templates/"+name)
				if err != nil {
					t.Fatal(err)
				}
				var rendered bytes.Buffer
				err = tpl.ExecuteTemplate(&rendered, "ente_base", map[string]interface{}{"Full": full, "UsagePercent": "95.2"})
				if err != nil {
					t.Fatal(err)
				}
				branch := "When your storage is full, new photos and videos will stop backing up."
				if name == "photos_storage_reminder.html" {
					branch = "Your Ente Photos storage is almost full."
				}
				if full {
					branch = "Your Ente Photos storage is full."
				}
				if !strings.Contains(rendered.String(), branch) {
					t.Fatalf("missing branch %q", branch)
				}
				if strings.Contains(rendered.String(), "Account:") {
					t.Fatal("account-email line must not appear in the body")
				}
				for _, text := range []string{"95.2%", "Settings", "trash"} {
					if !strings.Contains(rendered.String(), text) {
						t.Fatalf("missing %q", text)
					}
				}
			})
		}
	}
}

func TestPhotosStorageIndexPreservesOtherHistory(t *testing.T) {
	_, db, _ := setupStorageEmailTest(t, 900)
	for _, event := range []string{repo.PhotosStorageWarningTemplateID, repo.PhotosStorageReminderTemplateID, "repeatable_event"} {
		for attempt := 0; attempt < 2; attempt++ {
			_, err := db.Exec(`INSERT INTO notification_history(user_id,template_id,sent_time) VALUES(1,$1,1)`, event)
			conflict := event != "repeatable_event" && attempt == 1
			if (err != nil) != conflict {
				t.Fatalf("event=%s attempt=%d err=%v", event, attempt, err)
			}
		}
	}
}

func TestPhotosStorageSkipsSelfHosting(t *testing.T) {
	c, db, attempts := setupStorageEmailTest(t, 1100)
	testutil.ResetTables(t, db)
	const userID = 10000001
	testutil.InsertUser(t, db, testutil.UserFixture{UserID: userID, Email: "storage@ente.com", CreationTime: storageEmailCutoff})
	testutil.InsertUsage(t, db, userID, 1100)
	testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{UserID: userID, Storage: 1000, ProductID: ente.FreePlanProductID, ExpiryTime: time.MicrosecondsAfterHours(24)})
	c.SendPhotosStorageWarningMails()
	if len(*attempts) != 0 {
		t.Fatalf("attempts=%v", *attempts)
	}
	assertStorageWarningNotificationCount(t, db, userID, repo.PhotosStorageWarningTemplateID, 0)
	assertStorageWarningNotificationCount(t, db, userID, repo.PhotosStorageReminderTemplateID, 0)
}

func TestLegacyStorageRunRetainsLocalGuard(t *testing.T) {
	c, db, _ := setupStorageEmailTest(t, 1100)
	storageEmailSQL(t, db, `UPDATE subscriptions SET product_id='paid'`)
	old := sendStorageLimitExceededEmail
	t.Cleanup(func() { sendStorageLimitExceededEmail = old })
	attempts := 0
	sendStorageLimitExceededEmail = func(_ []string, _, _, _, _ string, _ map[string]interface{}, _ []map[string]interface{}) error {
		attempts++
		if attempts == 1 {
			storageEmailSQL(t, db, `UPDATE task_lock SET lock_until=0 WHERE task_name=$1`, StorageLimitExceededMailLock)
			c.SendStorageLimitExceededMails()
		}
		return nil
	}
	c.SendStorageLimitExceededMails()
	if attempts != 1 {
		t.Fatalf("overlapping legacy send attempts=%d, want 1", attempts)
	}
}

func TestPhotosStorageSendFailureContinuesBatch(t *testing.T) {
	for _, failure := range []error{errors.New("SMTP unavailable"), ente.ErrBadRequest, ente.NewBadRequestWithMessage("invalid recipient")} {
		t.Run(failure.Error(), func(t *testing.T) {
			c, db, _ := setupStorageEmailTest(t, 900)
			testutil.InsertUser(t, db, testutil.UserFixture{UserID: 2, Email: "next@ente.com", CreationTime: storageEmailCutoff})
			testutil.InsertUsage(t, db, 2, 900)
			testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{UserID: 2, Storage: 1000, ProductID: ente.FreePlanProductID, ExpiryTime: time.MicrosecondsAfterHours(24)})
			attempts := 0
			sendPhotosStorageWarningEmail = func(_ []string, _, _, _, _, _ string, _ map[string]interface{}, _ []map[string]interface{}) error {
				attempts++
				if attempts == 1 {
					return failure
				}
				return nil
			}
			c.SendPhotosStorageWarningMails()
			if attempts != 2 {
				t.Fatalf("batch attempts=%d, want 2", attempts)
			}
			c.SendPhotosStorageWarningMails()
			if attempts != 2 {
				t.Fatalf("consumed attempts repeated: %d", attempts)
			}
			for _, id := range []int64{1, 2} {
				assertStorageWarningNotificationCount(t, db, id, repo.PhotosStorageWarningTemplateID, 1)
			}
		})
	}
}
