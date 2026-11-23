package postmark

import (
	"encoding/json"
	"io"
	"net/http"
	"slices"
	"strings"
	"testing"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return f(req)
}

func TestSendBatchReturnsIndividualResults(t *testing.T) {
	previousClient := httpClient
	t.Cleanup(func() { httpClient = previousClient })
	var calls int
	httpClient = &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls++
		if req.Method != http.MethodPost || req.URL.String() != "https://api.postmarkapp.com/email/batch" {
			t.Errorf("unexpected Postmark request %s %s", req.Method, req.URL)
		}
		if req.Header.Get("X-Postmark-Server-Token") != "test-token" {
			t.Error("Postmark authentication header missing")
		}
		var messages []struct {
			From, To, MessageStream string
			Headers                 []Header
		}
		if err := json.NewDecoder(req.Body).Decode(&messages); err != nil {
			return nil, err
		}
		if len(messages) != 2 || messages[0].To != "subscriber@example.test" ||
			messages[1].To != "inactive@example.test" || messages[0].From != "team@example.test" ||
			messages[0].MessageStream != "product-mails" || len(messages[0].Headers) != 2 {
			t.Errorf("unexpected Postmark payload %+v", messages)
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Body:       io.NopCloser(strings.NewReader(`[{"ErrorCode":0},{"ErrorCode":406}]`)),
		}, nil
	})}

	client := Client{ServerToken: "test-token", From: "team@example.test"}
	codes, err := client.SendBatch(t.Context(), []Message{
		{To: "subscriber@example.test", MessageStream: "product-mails", Headers: []Header{
			{Name: "List-Unsubscribe", Value: "<https://example.test/email/unsubscribe?token=example>"},
			{Name: "List-Unsubscribe-Post", Value: "List-Unsubscribe=One-Click"},
		}},
		{To: "inactive@example.test", MessageStream: "product-mails"},
	})
	if err != nil || !slices.Equal(codes, []int{0, 406}) || calls != 1 {
		t.Fatalf("batch returned codes %v, err %v, made %d calls", codes, err, calls)
	}
}
