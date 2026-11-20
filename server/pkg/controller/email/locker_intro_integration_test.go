package email

import (
	"database/sql"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/ente/museum/internal/testutil"
	"github.com/ente/museum/pkg/controller/discord"
	"github.com/ente/museum/pkg/controller/lock"
	"github.com/ente/museum/pkg/repo"
	"github.com/ente/museum/pkg/utils/time"
)

type fakeProductMailer struct {
	prepareErr error
	startErr   error
	prepared   [][]string
	started    []string
}

func (m *fakeProductMailer) PrepareProductMailBatch(name string, emails []string) (int, error) {
	m.prepared = append(m.prepared, emails)
	return len(m.prepared), m.prepareErr
}

func (m *fakeProductMailer) StartProductMailCampaign(batchID int, name string, subject string, body string) error {
	m.started = append(m.started, fmt.Sprintf("%d|%s|%s|%t", batchID, name, subject, strings.Contains(body, `href="https://ente.com/locker"`) && !strings.Contains(body, "{{")))
	return m.startErr
}

func TestSendLockerIntroMailsStartsOneCampaignAndDoesNotRepeat(t *testing.T) {
	db, controller, mailer, now := setupLockerIntroTest(t)

	controller.SendLockerIntroMails(now)
	controller.SendLockerIntroMails(now + 24*time.MicroSecondsInOneHour)

	if want := [][]string{{"locker-1@example.com", "locker-2@example.com"}}; !slices.EqualFunc(mailer.prepared, want, slices.Equal) {
		t.Fatalf("prepared = %v, want %v", mailer.prepared, want)
	}
	if want := []string{"1|Locker intro 2026-11-05|Let Ente take care of your documents|true"}; !slices.Equal(mailer.started, want) {
		t.Fatalf("started = %v, want %v", mailer.started, want)
	}
	assertLockerIntroAttempts(t, db, 2)
}

func TestSendLockerIntroMailsRetriesWhenRecipientsCouldNotBePrepared(t *testing.T) {
	db, controller, mailer, now := setupLockerIntroTest(t)
	mailer.prepareErr = errors.New("listmonk is down")

	controller.SendLockerIntroMails(now)
	assertLockerIntroAttempts(t, db, 0)
	if len(mailer.started) != 0 {
		t.Fatalf("started = %v, want none", mailer.started)
	}

	mailer.prepareErr = nil
	controller.SendLockerIntroMails(now + 24*time.MicroSecondsInOneHour)
	assertLockerIntroAttempts(t, db, 2)
	if len(mailer.started) != 1 {
		t.Fatalf("started = %v, want one campaign", mailer.started)
	}
}

func TestSendLockerIntroMailsDoesNotRetryAfterCampaignFailsToStart(t *testing.T) {
	db, controller, mailer, now := setupLockerIntroTest(t)
	mailer.startErr = errors.New("listmonk is down")

	controller.SendLockerIntroMails(now)
	controller.SendLockerIntroMails(now + 24*time.MicroSecondsInOneHour)

	assertLockerIntroAttempts(t, db, 2)
	if len(mailer.prepared) != 1 {
		t.Fatalf("prepared = %v, want one batch", mailer.prepared)
	}
}

func TestSendLockerIntroMailsDoesNotStartWhenAttemptsCannotBeRecorded(t *testing.T) {
	db, controller, mailer, now := setupLockerIntroTest(t)
	if _, err := db.Exec(`ALTER TABLE notification_history ADD CONSTRAINT reject_locker_intro_test
		CHECK (user_id <> 2 OR template_id <> 'locker_intro')`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := db.Exec(`ALTER TABLE notification_history DROP CONSTRAINT reject_locker_intro_test`); err != nil {
			t.Fatal(err)
		}
	})

	controller.SendLockerIntroMails(now)

	assertLockerIntroAttempts(t, db, 0)
	if len(mailer.started) != 0 {
		t.Fatalf("started = %v, want none", mailer.started)
	}
}

func setupLockerIntroTest(t *testing.T) (*sql.DB, *EmailNotificationController, *fakeProductMailer, int64) {
	t.Helper()
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	for id := int64(1); id <= 2; id++ {
		testutil.InsertUser(t, db, testutil.UserFixture{UserID: id, Email: fmt.Sprintf("locker-%d@example.com", id), CreationTime: lockerIntroRolloutTime})
		if _, err := db.Exec(`INSERT INTO usage(user_id, storage_consumed, photos_file_count, locker_file_count) VALUES($1, 0, 1, 0)`, id); err != nil {
			t.Fatal(err)
		}
	}
	mailer := &fakeProductMailer{}
	controller := &EmailNotificationController{
		ProductMailer:           mailer,
		UserRepo:                &repo.UserRepository{DB: db, SecretEncryptionKey: testutil.SecretEncryptionKey()},
		NotificationHistoryRepo: &repo.NotificationHistoryRepository{DB: db},
		LockController:          &lock.LockController{TaskLockingRepo: &repo.TaskLockRepository{DB: db}, HostName: "locker-intro-test"},
		DiscordController:       &discord.DiscordController{},
	}
	return db, controller, mailer, lockerIntroRolloutTime + 4*24*time.MicroSecondsInOneHour
}

func assertLockerIntroAttempts(t *testing.T, db *sql.DB, want int) {
	t.Helper()
	var count int
	if err := db.QueryRow(`SELECT count(*) FROM notification_history WHERE template_id = 'locker_intro'`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != want {
		t.Fatalf("recorded attempts = %d, want %d", count, want)
	}
}
