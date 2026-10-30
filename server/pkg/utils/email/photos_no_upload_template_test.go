package email

import (
	"testing"

	"github.com/ente/museum/internal/testutil"
	"github.com/stretchr/testify/assert"
)

func TestPhotosNoUploadTemplateRenders(t *testing.T) {
	testutil.WithServerRoot(t)

	body, err := getMailBodyWithBase("legacy/legacy_base.html", "photos_no_upload.html", nil)

	assert.NoError(t, err)
	assert.Contains(t, body, "https://ente.com/download/desktop")
}
