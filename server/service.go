package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

var hexDigest = regexp.MustCompile(`^[0-9a-f]{64}$`)
var noncePattern = regexp.MustCompile(`^[0-9a-f]{32}$`)
var rawURL = base64.RawURLEncoding

func digest(s string) string { sum := sha256.Sum256([]byte(s)); return hex.EncodeToString(sum[:]) }

func checksum(body string) byte {
	sum := 0
	for i := range body {
		sum += strings.IndexByte(alphabet, body[i]) * (2*(i%15) + 1)
	}
	return alphabet[sum%len(alphabet)]
}

func normalizeKey(s string) (string, bool) {
	s = strings.ToUpper(strings.TrimSpace(s))
	parts := strings.Split(s, "-")
	if len(parts) != 5 || parts[0] != "LULU" {
		return "", false
	}
	for _, part := range parts[1:] {
		if len(part) != 4 || strings.ContainsFunc(part, func(r rune) bool { return !strings.ContainsRune(alphabet, r) }) {
			return "", false
		}
	}
	body := strings.Join(parts[1:], "")
	return s, body[15] == checksum(body[:15])
}

func newKey() (string, error) {
	b := make([]byte, 15)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	for i := range b {
		b[i] = alphabet[int(b[i])%len(alphabet)]
	}
	b = append(b, checksum(string(b)))
	return fmt.Sprintf("LULU-%s-%s-%s-%s", b[:4], b[4:8], b[8:12], b[12:]), nil
}

type fingerprint struct {
	Platform string   `json:"platform"`
	Parts    []string `json:"parts"`
}

func (f fingerprint) hash() string { return digest(f.Platform + ":" + strings.Join(f.Parts, ":")) }
func (f fingerprint) valid() bool {
	if !(f.Platform == "windows" && len(f.Parts) == 3 || f.Platform == "android" && len(f.Parts) == 1) {
		return false
	}
	count := 0
	for _, p := range f.Parts {
		if p == "" {
			continue
		}
		if !hexDigest.MatchString(p) {
			return false
		}
		count++
	}
	return count >= 2 || f.Platform == "android" && count == 1
}

type claims struct {
	Version     int         `json:"v"`
	KeyID       int64       `json:"key_id"`
	IssuedAt    int64       `json:"issued_at"`
	MachineHash string      `json:"machine_hash"`
	Device      fingerprint `json:"device"`
}

type activationServer struct {
	db      *sql.DB
	signing ed25519.PrivateKey
}

func openDB(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	_, err = db.Exec(`PRAGMA busy_timeout=5000;
 CREATE TABLE IF NOT EXISTS activation_keys (
 id INTEGER PRIMARY KEY, digest TEXT NOT NULL UNIQUE, note TEXT NOT NULL,
 issued_at INTEGER, machine_hash TEXT, revoked INTEGER NOT NULL DEFAULT 0
 );
 CREATE TABLE IF NOT EXISTS revoked_devices (machine_hash TEXT PRIMARY KEY);`)
	if err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

func (s activationServer) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/status", func(w http.ResponseWriter, r *http.Request) {
		if err := s.db.PingContext(r.Context()); err != nil {
			reply(w, 503, nil)
			return
		}
		nonce := r.URL.Query().Get("nonce")
		result := map[string]any{"ok": true}
		if nonce != "" {
			if !noncePattern.MatchString(nonce) {
				reply(w, 400, nil)
				return
			}
			result["proof"] = rawURL.EncodeToString(ed25519.Sign(s.signing, []byte("lulu-status-v1:"+nonce)))
		}
		reply(w, 200, result)
	})
	mux.HandleFunc("POST /v1/activate", s.activate)
	mux.HandleFunc("POST /v1/validate", s.validate)
	return mux
}

func reply(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func readJSON(w http.ResponseWriter, r *http.Request, out any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	dec.DisallowUnknownFields()
	if dec.Decode(out) != nil || dec.Decode(new(any)) != io.EOF {
		reply(w, 400, nil)
		return false
	}
	return true
}

func (s activationServer) activate(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Key         string `json:"key"`
		MachineCode string `json:"machine_code"`
		fingerprint
	}
	if !readJSON(w, r, &req) {
		return
	}
	machineHash := req.fingerprint.hash()
	code := strings.ToUpper(machineHash[:16])
	code = code[:4] + "-" + code[4:8] + "-" + code[8:12] + "-" + code[12:]
	if !req.fingerprint.valid() || req.MachineCode != code {
		reply(w, 400, nil)
		return
	}
	key, ok := normalizeKey(req.Key)
	if !ok {
		reply(w, 404, nil)
		return
	}
	token, status := s.consume(r.Context(), key, req.fingerprint, machineHash)
	if status != 200 {
		reply(w, status, nil)
		return
	}
	reply(w, 200, map[string]string{"token": token})
}

func (s activationServer) consume(ctx context.Context, key string, f fingerprint, machineHash string) (string, int) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", 500
	}
	defer tx.Rollback()
	now := time.Now().Unix()
	var id int64
	err = tx.QueryRowContext(ctx, `UPDATE activation_keys SET issued_at=?, machine_hash=?
 WHERE digest=? AND issued_at IS NULL AND revoked=0 AND NOT EXISTS
 (SELECT 1 FROM revoked_devices WHERE machine_hash=?) RETURNING id`, now, machineHash, digest(key), machineHash).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		var issued, keyRevoked, deviceRevoked bool
		err = tx.QueryRowContext(ctx, `SELECT issued_at IS NOT NULL, revoked,
 EXISTS (SELECT 1 FROM revoked_devices WHERE machine_hash=?)
 FROM activation_keys WHERE digest=?`, machineHash, digest(key)).Scan(&issued, &keyRevoked, &deviceRevoked)
		if errors.Is(err, sql.ErrNoRows) {
			return "", 404
		}
		if err != nil {
			return "", 500
		}
		if keyRevoked {
			return "", 404
		}
		if issued {
			return "", 409
		}
		if deviceRevoked {
			return "", 403
		}
		return "", 500
	}
	if err != nil {
		return "", 500
	}
	payload, err := json.Marshal(claims{1, id, now, machineHash, f})
	if err != nil {
		return "", 500
	}
	token := rawURL.EncodeToString(payload) + "." + rawURL.EncodeToString(ed25519.Sign(s.signing, payload))
	if tx.Commit() != nil {
		return "", 500
	}
	return token, 200
}

func (s activationServer) validate(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Token string `json:"token"`
		Nonce string `json:"nonce"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if !noncePattern.MatchString(req.Nonce) {
		reply(w, 400, nil)
		return
	}
	head, tail, ok := strings.Cut(req.Token, ".")
	payload, pErr := rawURL.DecodeString(head)
	sig, sErr := rawURL.DecodeString(tail)
	var c claims
	if !ok || pErr != nil || sErr != nil || !ed25519.Verify(s.signing.Public().(ed25519.PublicKey), payload, sig) || json.Unmarshal(payload, &c) != nil || c.Version != 1 {
		reply(w, 200, map[string]bool{"valid": false, "revoked": false})
		return
	}
	var revoked bool
	err := s.db.QueryRowContext(r.Context(), `SELECT revoked OR EXISTS(SELECT 1 FROM revoked_devices WHERE machine_hash=?)
 FROM activation_keys WHERE id=? AND machine_hash=? AND issued_at=?`, c.MachineHash, c.KeyID, c.MachineHash, c.IssuedAt).Scan(&revoked)
	if errors.Is(err, sql.ErrNoRows) {
		reply(w, 200, map[string]bool{"valid": false, "revoked": false})
		return
	}
	if err != nil {
		reply(w, 500, nil)
		return
	}
	result := map[string]any{"valid": !revoked, "revoked": revoked}
	if revoked {
		message := "lulu-revoked-v1:" + req.Nonce + ":" + digest(req.Token)
		result["proof"] = rawURL.EncodeToString(ed25519.Sign(s.signing, []byte(message)))
	}
	reply(w, 200, result)
}
