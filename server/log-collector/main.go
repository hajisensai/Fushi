package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Config 全部从环境变量注入，绝不写进源码/仓库。
type Config struct {
	UploadToken  string
	BasicUser    string
	BasicPass    string
	EOSecret     string
	DataDir      string
	MaxBodyBytes int64
	Retain       int
	ListenAddr   string
}

type uploadPayload struct {
	Kind       string `json:"kind"`
	AppVersion string `json:"app_version"`
	Platform   string `json:"platform"`
	Device     string `json:"device"`
	Ts         string `json:"ts"`
	Log        string `json:"log"`
}

var idPattern = regexp.MustCompile(`^\d{8}-\d{6}-[a-z]+-[a-z0-9]{6}\.txt$`)
var platSanitize = regexp.MustCompile(`[^a-z]`)

const randAlphabet = "abcdefghijklmnopqrstuvwxyz0123456789"

func ctEqual(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func randCode(n int) string {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		for i := range buf {
			buf[i] = byte(time.Now().UnixNano() >> (i * 8))
		}
	}
	out := make([]byte, n)
	for i, b := range buf {
		out[i] = randAlphabet[int(b)%len(randAlphabet)]
	}
	return string(out)
}

func sanitizePlatform(p string) string {
	p = strings.ToLower(p)
	p = platSanitize.ReplaceAllString(p, "")
	if p == "" {
		return "unknown"
	}
	if len(p) > 16 {
		p = p[:16]
	}
	return p
}

// securityHeaders 给所有响应钉上防御头。
func securityHeaders(w http.ResponseWriter) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
}

func (c Config) handleUpload(w http.ResponseWriter, r *http.Request) {
	securityHeaders(w)
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	// 防绕过 EO：必须带 EO 回源注入的密钥头。
	if !ctEqual(r.Header.Get("X-EO-Secret"), c.EOSecret) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	// 弱上传凭据（App 内置）。
	if !ctEqual(r.Header.Get("X-Upload-Token"), c.UploadToken) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	// 限大小：超限读取直接 413。
	r.Body = http.MaxBytesReader(w, r.Body, c.MaxBodyBytes)
	var p uploadPayload
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		if strings.Contains(err.Error(), "http: request body too large") {
			http.Error(w, "too large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	// 文件名完全由服务端生成，绝不用客户端字段拼路径。
	name := time.Now().UTC().Format("20060102-150405") + "-" +
		sanitizePlatform(p.Platform) + "-" + randCode(6) + ".txt"

	// 元信息作为文件头部写入正文（去除换行注入）。
	header := strings.NewReplacer("\n", " ", "\r", " ")
	content := "# kind: " + header.Replace(p.Kind) + "\n" +
		"# app_version: " + header.Replace(p.AppVersion) + "\n" +
		"# platform: " + header.Replace(p.Platform) + "\n" +
		"# device: " + header.Replace(p.Device) + "\n" +
		"# ts: " + header.Replace(p.Ts) + "\n\n" + p.Log

	if err := os.MkdirAll(c.DataDir, 0o750); err != nil {
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	if err := os.WriteFile(filepath.Join(c.DataDir, name), []byte(content), 0o640); err != nil {
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	c.rotate()

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]string{"id": name})
}

// rotate 保留最近 Retain 个文件，删最旧的，防塞盘。
func (c Config) rotate() {
	if c.Retain <= 0 {
		return
	}
	entries, err := os.ReadDir(c.DataDir)
	if err != nil {
		return
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() && idPattern.MatchString(e.Name()) {
			names = append(names, e.Name())
		}
	}
	if len(names) <= c.Retain {
		return
	}
	sort.Strings(names) // 文件名前缀是时间戳 → 字典序即时间序
	for _, old := range names[:len(names)-c.Retain] {
		_ = os.Remove(filepath.Join(c.DataDir, old))
	}
}

// newServer 装配路由（查看路由在 Task 6 补）。
func newServer(c Config) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/logs", c.handleUpload)
	return mux
}

func main() {
	cfg := Config{
		UploadToken:  os.Getenv("UPLOAD_TOKEN"),
		BasicUser:    os.Getenv("BASIC_USER"),
		BasicPass:    os.Getenv("BASIC_PASS"),
		EOSecret:     os.Getenv("EO_SECRET"),
		DataDir:      envOr("DATA_DIR", "/var/lib/hibiki-logs/data"),
		MaxBodyBytes: envInt64("MAX_BODY_BYTES", 1<<20),
		Retain:       int(envInt64("RETAIN", 2000)),
		ListenAddr:   envOr("LISTEN_ADDR", "127.0.0.1:8787"),
	}
	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           newServer(cfg),
		ReadHeaderTimeout: 10 * time.Second,
	}
	if err := srv.ListenAndServe(); err != nil {
		os.Exit(1)
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt64(k string, def int64) int64 {
	v := os.Getenv(k)
	if v == "" {
		return def
	}
	var n int64
	for _, ch := range v {
		if ch < '0' || ch > '9' {
			return def
		}
		n = n*10 + int64(ch-'0')
	}
	return n
}
