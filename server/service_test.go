package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"net/http/httptest"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func TestConcurrentActivationAndSignedRevocation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "activation.db")
	db, err := openDB(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	secondDB, err := openDB(path)
	if err != nil {
		t.Fatal(err)
	}
	defer secondDB.Close()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	key, err := newKey()
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(`INSERT INTO activation_keys(digest,note) VALUES (?,?)`, digest(key), "test"); err != nil {
		t.Fatal(err)
	}
	first := activationServer{db, private}
	second := activationServer{secondDB, private}
	f := fingerprint{"windows", []string{digest("board"), digest("disk"), digest("guid")}}
	hash := f.hash()
	code := strings.ToUpper(hash[:16])
	code = code[:4] + "-" + code[4:8] + "-" + code[8:12] + "-" + code[12:]
	body, err := json.Marshal(map[string]any{"key": key, "machine_code": code, "platform": f.Platform, "parts": f.Parts})
	if err != nil {
		t.Fatal(err)
	}
	results := make(chan *httptest.ResponseRecorder, 2)
	start := make(chan struct{})
	for _, s := range []activationServer{first, second} {
		go func(s activationServer) {
			<-start
			w := httptest.NewRecorder()
			s.handler().ServeHTTP(w, httptest.NewRequest("POST", "/v1/activate", bytes.NewReader(body)))
			results <- w
		}(s)
	}
	close(start)
	responses := []*httptest.ResponseRecorder{<-results, <-results}
	sort.Slice(responses, func(i, j int) bool { return responses[i].Code < responses[j].Code })
	if responses[0].Code != 200 || responses[1].Code != 409 {
		t.Fatalf("got status codes %d and %d", responses[0].Code, responses[1].Code)
	}
	var activated struct {
		Token string `json:"token"`
	}
	if err = json.Unmarshal(responses[0].Body.Bytes(), &activated); err != nil || activated.Token == "" {
		t.Fatal("missing token")
	}
	const nonce = "0123456789abcdef0123456789abcdef"
	body, err = json.Marshal(map[string]string{"token": activated.Token, "nonce": nonce})
	if err != nil {
		t.Fatal(err)
	}
	validate := func() map[string]any {
		w := httptest.NewRecorder()
		first.handler().ServeHTTP(w, httptest.NewRequest("POST", "/v1/validate", bytes.NewReader(body)))
		var result map[string]any
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &result) != nil {
			t.Fatal("validation failed")
		}
		return result
	}
	if validate()["valid"] != true {
		t.Fatal("new token not valid")
	}
	if err = devices(db, []string{"revoke", hash}); err != nil {
		t.Fatal(err)
	}
	result := validate()
	proof, ok := result["proof"].(string)
	sig, _ := rawURL.DecodeString(proof)
	if result["revoked"] != true || result["valid"] != false || !ok ||
		!ed25519.Verify(public, []byte("lulu-revoked-v1:"+nonce+":"+digest(activated.Token)), sig) {
		t.Fatal("expected signed revocation")
	}
}

func TestChecksumRejectsEverySingleCharacterChange(t *testing.T) {
	key, err := newKey()
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := normalizeKey(key); !ok {
		t.Fatal("generated key was invalid")
	}
	for i := 5; i < len(key); i++ {
		if key[i] == '-' {
			continue
		}
		for j := range alphabet {
			if key[i] == alphabet[j] {
				continue
			}
			changed := key[:i] + alphabet[j:j+1] + key[i+1:]
			if _, ok := normalizeKey(changed); ok {
				t.Fatalf("changed position %d passed", i)
			}
		}
	}
}
