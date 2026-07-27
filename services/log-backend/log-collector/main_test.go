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

func basicAuthReq(method, target, user, pass string) *http.Request {
	r := httptest.NewRequest(method, target, nil)
	if user != "" || pass != "" {
		r.SetBasicAuth(user, pass)
	}
	return r
}

func seedOneLog(t *testing.T, cfg Config, h http.Handler, log string) string {
	t.Helper()
	body, _ := json.Marshal(uploadPayload{Kind: "error", Platform: "android", Log: log})
	w := httptest.NewRecorder()
	h.ServeHTTP(w, uploadReq("good-token", "eo-shared", string(body)))
	if w.Code != http.StatusOK {
		t.Fatalf("seed upload failed: %d", w.Code)
	}
	var resp struct{ ID string }
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	return resp.ID
}

func TestViewerRequiresBasicAuth(t *testing.T) {
	h := newServer(testConfig(t))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, basicAuthReq(http.MethodGet, "/", "", ""))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("want 401 without auth, got %d", w.Code)
	}
}

func TestViewerWrongPassword(t *testing.T) {
	h := newServer(testConfig(t))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, basicAuthReq(http.MethodGet, "/", "admin", "nope"))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", w.Code)
	}
}

func TestViewerListsLogs(t *testing.T) {
	cfg := testConfig(t)
	h := newServer(cfg)
	id := seedOneLog(t, cfg, h, "hello")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, basicAuthReq(http.MethodGet, "/", "admin", "secret-pass"))
	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", w.Code)
	}
	if !strings.Contains(w.Body.String(), id) {
		t.Fatalf("listing missing id %q", id)
	}
}

func TestViewLogServedAsPlainText_XSSInert(t *testing.T) {
	cfg := testConfig(t)
	h := newServer(cfg)
	id := seedOneLog(t, cfg, h, "<script>alert(1)</script>")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, basicAuthReq(http.MethodGet, "/log/"+id, "admin", "secret-pass"))
	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", w.Code)
	}
	ct := w.Header().Get("Content-Type")
	if !strings.HasPrefix(ct, "text/plain") {
		t.Fatalf("log must be text/plain (inert), got %q", ct)
	}
	if w.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("missing nosniff")
	}
	if strings.Contains(ct, "html") {
		t.Fatalf("must not be html")
	}
}

func TestViewLogRejectsPathTraversal(t *testing.T) {
	h := newServer(testConfig(t))
	cases := []struct {
		path     string
		wantCode int // 0 表示「只要不是 200 即可」
	}{
		{"/log/..%2f..%2fetc%2fpasswd", 0},                                   // ServeMux 清洗 → 3xx，从不读盘
		{"/log/evil.txt", http.StatusNotFound},                               // 过 validLogID 被拒
		{"/log/20260606-000000-android-ab12cd.txt.bak", http.StatusNotFound}, // .bak 被锚定正则拒
	}
	for _, tc := range cases {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, basicAuthReq(http.MethodGet, tc.path, "admin", "secret-pass"))
		if w.Code == http.StatusOK {
			t.Fatalf("%s: served (200), must be rejected", tc.path)
		}
		if tc.wantCode != 0 && w.Code != tc.wantCode {
			t.Fatalf("%s: want %d, got %d", tc.path, tc.wantCode, w.Code)
		}
	}
}

func TestValidateConfigRejectsEmptySecrets(t *testing.T) {
	full := Config{EOSecret: "a", UploadToken: "b", BasicUser: "c", BasicPass: "d"}
	if m := validateConfig(full); len(m) != 0 {
		t.Fatalf("full config should pass, got missing=%v", m)
	}
	if m := validateConfig(Config{}); len(m) != 4 {
		t.Fatalf("empty config should report 4 missing, got %v", m)
	}
	// 单缺一项也要被抓
	noToken := full
	noToken.UploadToken = ""
	if m := validateConfig(noToken); len(m) != 1 || m[0] != "UPLOAD_TOKEN" {
		t.Fatalf("missing token not caught: %v", m)
	}
}

func TestUploadRejectsNonPost(t *testing.T) {
	h := newServer(testConfig(t))
	r := httptest.NewRequest(http.MethodGet, "/api/logs", nil)
	r.Header.Set("X-EO-Secret", "eo-shared")
	r.Header.Set("X-Upload-Token", "good-token")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("want 405, got %d", w.Code)
	}
}

func TestUploadLongPlatformFilenameBounded(t *testing.T) {
	cfg := testConfig(t)
	h := newServer(cfg)
	body := `{"kind":"error","platform":"` + strings.Repeat("z", 100) + `","log":"x"}`
	w := httptest.NewRecorder()
	h.ServeHTTP(w, uploadReq("good-token", "eo-shared", body))
	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", w.Code)
	}
	entries, _ := os.ReadDir(cfg.DataDir)
	if len(entries) != 1 {
		t.Fatalf("want 1 file, got %d", len(entries))
	}
	// 文件名仍匹配白名单形状（platform 段被截到 <=16）
	if !idPattern.MatchString(entries[0].Name()) {
		t.Fatalf("filename not whitelist-shaped: %q", entries[0].Name())
	}
}

func TestValidateLogIDUnit(t *testing.T) {
	if validLogID("../../etc/passwd") {
		t.Fatal("must reject traversal")
	}
	if validLogID("evil.txt") {
		t.Fatal("must reject non-pattern")
	}
	if !validLogID("20260606-123456-android-ab12cd.txt") {
		t.Fatal("must accept valid id")
	}
}
