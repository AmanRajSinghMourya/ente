package email

import (
	"testing"

	"github.com/ente/museum/internal/testutil"
	"github.com/stretchr/testify/require"
)

func TestAlbumShareTemplate(t *testing.T) {
	testutil.WithServerRoot(t)
	for _, tc := range []struct {
		count   int
		message string
	}{{1, "shared an album with you."}, {5, "shared 5 albums with you."}} {
		t.Run(tc.message, func(t *testing.T) {
			body, err := getMailBodyWithBase("base.html", "album_shared.html", map[string]interface{}{
				"SenderEmail": "<sender>@example.com", "AlbumCount": tc.count, "PhotosURL": "https://photos.example.com",
			})
			require.NoError(t, err)
			require.Contains(t, body, "&lt;sender&gt;@example.com "+tc.message)
			require.Contains(t, body, `href="https://photos.example.com"`)
			require.Contains(t, body, "Open Ente Photos")
			require.NotContains(t, body, "<sender>")
		})
	}
}
