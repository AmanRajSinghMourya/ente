package email

import (
	"testing"

	"github.com/ente/museum/internal/testutil"
	"github.com/stretchr/testify/require"
)

func TestAlbumShareTemplate(t *testing.T) {
	testutil.WithServerRoot(t)
	for _, tc := range []struct {
		count       int
		message     string
		instruction string
	}{{1, "shared an album with you.", "Open Ente Photos to view it."}, {5, "shared 5 albums with you.", "Open Ente Photos to view them."}} {
		t.Run(tc.message, func(t *testing.T) {
			body, err := getMailBodyWithBase("base.html", "album_shared.html", map[string]interface{}{
				"SenderEmail": "<sender>@example.com", "AlbumCount": tc.count,
			})
			require.NoError(t, err)
			require.Contains(t, body, "&lt;sender&gt;@example.com "+tc.message)
			require.NotContains(t, body, `class="button"`)
			require.NotContains(t, body, `href="https://photos.ente.com"`)
			require.Contains(t, body, tc.instruction)
			require.NotContains(t, body, "<sender>")
		})
	}
}
