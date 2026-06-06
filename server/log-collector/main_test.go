package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strings"
	"testing"
)

func testConfig(t *testing.T) Config {
	t.Helper()
	return Config{
		UploadToken:  "good-token",
		BasicUser:    "admin",
		BasicPass:    "secret-pass",
		EOSecret:     "eo-shared",
		DataDir:      t.TempDir(),
		MaxBodyBytes: 1024,
		Retain:       100,
	}
}

func uploadReq(token, eo, body string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/api/logs", strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("X-Upload-Token", token)
	}
	if eo != "" {
		r.Header.Set("X-EO-Secret", eo)
	}
	return r
}

func TestUploadHappyPath(t *testing.T) {
	cfg := testConfig(t)
	h := newServer(cfg)
	body := `{"kind":"error","app_version":"1.0+1","platform":"android","device":"Pixel","ts":"2026-06-06T00:00:00Z","log":"hello"}`
	w := httptest.NewRecorder()
	h.ServeHTTP(w, uploadReq("good-token", "eo-shared", body))

	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d (%s)", w.Code, w.Body.String())
	}
	var resp struct{ ID string }
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("bad json: %v", err)
	}
	if !regexp.MustCompile(`^\d{8}-\d{6}-[a-z]+-[a-z0-9]{6}\.txt$`).MatchString(resp.ID) {
		t.Fatalf("id not whitelisted shape: %q", resp.ID)
	}
	if _, err := os.Stat(cfg.DataDir + "/" + resp.ID); err != nil {
		t.Fatalf("file not written: %v", err)
	}
}

func TestUploadWrongToken(t *testing.T) {
	h := newServer(testConfig(t))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, uploadReq("bad", "eo-shared", `{"log":"x"}`))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", w.Code)
	}
}

func TestUploadMissingEOSecret(t *testing.T) {
	h := newServer(testConfig(t))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, uploadReq("good-token", "", `{"log":"x"}`))
	if w.Code != http.StatusForbidden {
		t.Fatalf("want 403 (bare-origin bypass blocked), got %d", w.Code)
	}
}

func TestUploadTooLarge(t *testing.T) {
	h := newServer(testConfig(t)) // MaxBodyBytes=1024
	big := `{"log":"` + strings.Repeat("A", 4096) + `"}`
	w := httptest.NewRecorder()
	h.ServeHTTP(w, uploadReq("good-token", "eo-shared", big))
	if w.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("want 413, got %d", w.Code)
	}
}

func TestUploadMaliciousPlatformStaysInDataDir(t *testing.T) {
	cfg := testConfig(t)
	h := newServer(cfg)
	body := `{"kind":"error","platform":"../../etc","device":"x","log":"y"}`
	w := httptest.NewRecorder()
	h.ServeHTTP(w, uploadReq("good-token", "eo-shared", body))
	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", w.Code)
	}
	entries, _ := os.ReadDir(cfg.DataDir)
	if len(entries) != 1 {
		t.Fatalf("expected 1 file in data dir, got %d", len(entries))
	}
	if strings.Contains(entries[0].Name(), "/") || strings.Contains(entries[0].Name(), "..") {
		t.Fatalf("filename not sanitized: %q", entries[0].Name())
	}
}
