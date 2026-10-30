package email

import (
	"bytes"
	"database/sql"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net"
	"net/mail"
	"net/textproto"
	"strings"
	"testing"
	stdtime "time"

	"github.com/ente/museum/internal/testutil"
	"github.com/ente/museum/pkg/controller/lock"
	"github.com/ente/museum/pkg/repo"
	"github.com/ente/museum/pkg/utils/time"
	"github.com/spf13/viper"
)

func TestSendLockerIntroMailsDeliveryAndRepeatSuppression(t *testing.T) {
	db, controller, now := setupLockerIntroTest(t, 2)
	testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{UserID: 2, Storage: 1 << 30, ExpiryTime: now + time.MicroSecondsInOneHour})
	smtp := captureLockerIntroSMTP(t, db, false)
	controller.SendLockerIntroMails(now)
	assertLockerIntroAttempts(t, db, smtp, 2)

	var firstBody string
	for range 2 {
		message, err := mail.ReadMessage(bytes.NewReader(<-smtp.messages))
		if err != nil {
			t.Fatal(err)
		}
		from, err := mail.ParseAddress(message.Header.Get("From"))
		if err != nil || from.Name != "Ente" || from.Address != "team@ente.com" {
			t.Fatalf("sender = %v, %v", from, err)
		}
		subject, err := (&mime.WordDecoder{}).DecodeHeader(message.Header.Get("Subject"))
		if err != nil || subject != "Meet Ente Locker" {
			t.Fatalf("subject = %q, %v", subject, err)
		}
		if message.Header.Get("List-Unsubscribe") != "" {
			t.Fatal("unexpected List-Unsubscribe header")
		}
		_, params, err := mime.ParseMediaType(message.Header.Get("Content-Type"))
		if err != nil {
			t.Fatal(err)
		}
		parts := multipart.NewReader(message.Body, params["boundary"])
		part, err := parts.NextPart()
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(part)
		if err != nil {
			t.Fatal(err)
		}
		for _, link := range []string{"https://ente.com/locker/get", "https://ente.com/blog/locker/", "mailto:support@ente.com"} {
			if !bytes.Contains(body, []byte(`href="`+link+`"`)) {
				t.Errorf("missing link %s", link)
			}
		}
		if !bytes.Contains(body, []byte(`src="https://email-assets.ente.com/locker-intro.png"`)) {
			t.Fatal("missing hosted illustration")
		}
		if firstBody == "" {
			firstBody = string(body)
		} else if string(body) != firstBody {
			t.Fatal("free and paid users received different email bodies")
		}
	}
	controller.SendLockerIntroMails(now + 24*time.MicroSecondsInOneHour)
	assertLockerIntroAttempts(t, db, smtp, 2)
}

func TestSendLockerIntroMailsFailedDeliveryIsNotRetried(t *testing.T) {
	db, controller, now := setupLockerIntroTest(t, 1)
	smtp := captureLockerIntroSMTP(t, db, true)
	controller.SendLockerIntroMails(now)
	assertLockerIntroAttempts(t, db, smtp, 1)
	controller.SendLockerIntroMails(now + 24*time.MicroSecondsInOneHour)
	assertLockerIntroAttempts(t, db, smtp, 1)
	if len(smtp.messages) != 0 {
		t.Fatal("rejected delivery unexpectedly succeeded")
	}
}

func TestSendLockerIntroMailsHistoryFailureDoesNotSend(t *testing.T) {
	db, controller, now := setupLockerIntroTest(t, 2)
	if _, err := db.Exec(`ALTER TABLE notification_history ADD CONSTRAINT reject_locker_intro_test
		CHECK (user_id <> 1 OR template_id <> 'locker_intro')`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := db.Exec(`ALTER TABLE notification_history DROP CONSTRAINT reject_locker_intro_test`); err != nil {
			t.Fatal(err)
		}
	})
	smtp := captureLockerIntroSMTP(t, db, false)
	controller.SendLockerIntroMails(now)
	assertLockerIntroAttempts(t, db, smtp, 1)
	if recipient := <-smtp.recipients; recipient != "locker-2@example.com" {
		t.Fatalf("recipient = %s, want locker-2@example.com", recipient)
	}
}

func setupLockerIntroTest(t *testing.T, users int) (*sql.DB, *EmailNotificationController, int64) {
	t.Helper()
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })
	for id := int64(1); id <= int64(users); id++ {
		testutil.InsertUser(t, db, testutil.UserFixture{UserID: id, Email: fmt.Sprintf("locker-%d@example.com", id), CreationTime: lockerIntroRolloutTime})
		if _, err := db.Exec(`INSERT INTO usage(user_id, storage_consumed, photos_file_count, locker_file_count) VALUES($1, 0, 1, 0)`, id); err != nil {
			t.Fatal(err)
		}
	}
	controller := &EmailNotificationController{
		UserRepo:                &repo.UserRepository{DB: db, SecretEncryptionKey: testutil.SecretEncryptionKey()},
		NotificationHistoryRepo: &repo.NotificationHistoryRepository{DB: db},
		LockController:          &lock.LockController{TaskLockingRepo: &repo.TaskLockRepository{DB: db}, HostName: "locker-intro-test"},
	}
	return db, controller, lockerIntroRolloutTime + 4*24*time.MicroSecondsInOneHour
}

type lockerIntroSMTP struct {
	recipients chan string
	messages   chan []byte
	errors     chan error
}

func captureLockerIntroSMTP(t *testing.T, db *sql.DB, reject bool) *lockerIntroSMTP {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	host, port, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	for key, value := range map[string]string{"smtp.host": host, "smtp.port": port, "smtp.email": "", "smtp.sender-name": "", "smtp.username": "", "smtp.password": "", "smtp.encryption": ""} {
		oldValue := viper.Get(key)
		viper.Set(key, value)
		t.Cleanup(func() { viper.Set(key, oldValue) })
	}
	capture := &lockerIntroSMTP{recipients: make(chan string, 4), messages: make(chan []byte, 4), errors: make(chan error, 4)}
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			if err := capture.receive(conn, db, reject); err != nil {
				capture.errors <- err
			}
		}
	}()
	t.Cleanup(func() {
		listener.Close()
		<-done
		if len(capture.errors) != 0 {
			t.Error(<-capture.errors)
		}
	})
	return capture
}

func (capture *lockerIntroSMTP) receive(conn net.Conn, db *sql.DB, reject bool) error {
	defer conn.Close()
	if err := conn.SetDeadline(stdtime.Now().Add(5 * stdtime.Second)); err != nil {
		return err
	}
	client := textproto.NewConn(conn)
	if err := client.PrintfLine("220 localhost SMTP"); err != nil {
		return err
	}
	for {
		line, err := client.ReadLine()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		reply := "250 OK"
		switch {
		case strings.HasPrefix(line, "RCPT TO:"):
			recipient := strings.TrimSuffix(strings.TrimPrefix(line, "RCPT TO:<"), ">")
			capture.recipients <- recipient
			var userID int64
			if _, err := fmt.Sscanf(recipient, "locker-%d@example.com", &userID); err != nil {
				return err
			}
			var count int
			if err := db.QueryRow(`SELECT count(*) FROM notification_history WHERE user_id = $1 AND template_id = 'locker_intro'`, userID).Scan(&count); err != nil {
				return err
			}
			if count != 1 {
				return fmt.Errorf("SMTP reached before attempt was recorded for user %d: history count %d", userID, count)
			}
			if reject {
				reply = "550 rejected for test"
			}
		case line == "DATA":
			if err := client.PrintfLine("354 Send message"); err != nil {
				return err
			}
			message, err := client.ReadDotBytes()
			if err != nil {
				return err
			}
			capture.messages <- message
		case line == "QUIT":
			return client.PrintfLine("221 Bye")
		}
		if err := client.PrintfLine("%s", reply); err != nil {
			return err
		}
	}
}

func assertLockerIntroAttempts(t *testing.T, db *sql.DB, smtp *lockerIntroSMTP, want int) {
	t.Helper()
	var count int
	if err := db.QueryRow(`SELECT count(*) FROM notification_history WHERE template_id = 'locker_intro'`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != want || len(smtp.recipients) != want {
		t.Fatalf("history rows = %d, SMTP attempts = %d; want %d each", count, len(smtp.recipients), want)
	}
}
