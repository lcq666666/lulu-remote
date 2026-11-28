package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"time"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	data, err := os.UserConfigDir()
	if err != nil {
		return err
	}
	options := flag.NewFlagSet("lulu-auth", flag.ContinueOnError)
	dir := options.String("data-dir", filepath.Join(data, "LuluActivation"), "private data directory")
	if err = options.Parse(args); err != nil {
		return err
	}
	args = options.Args()
	if len(args) == 0 {
		return errors.New("choose init, serve, keys, or devices (see server/README.md)")
	}
	if err = os.MkdirAll(*dir, 0700); err != nil {
		return err
	}
	seedPath := filepath.Join(*dir, "signing.seed")
	if args[0] == "init" && len(args) == 1 {
		return initSigning(seedPath)
	}
	seed, err := os.ReadFile(seedPath)
	if err != nil || len(seed) != ed25519.SeedSize {
		return errors.New("missing or unreadable signing seed; run init once in your data directory")
	}
	signing := ed25519.NewKeyFromSeed(seed)
	db, err := openDB(filepath.Join(*dir, "activation.db"))
	if err != nil {
		return errors.New("cannot open the activation database")
	}
	defer db.Close()
	switch args[0] {
	case "serve":
		return serve(activationServer{db, signing}, args[1:])
	case "keys":
		return keys(db, args[1:])
	case "devices":
		return devices(db, args[1:])
	default:
		return errors.New("choose init, serve, keys, or devices")
	}
}

func initSigning(path string) error {
	seed, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		seed = make([]byte, ed25519.SeedSize)
		if _, err = rand.Read(seed); err != nil {
			return err
		}
		file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return err
		}
		_, writeErr := file.Write(seed)
		closeErr := file.Close()
		if writeErr != nil {
			return writeErr
		}
		if closeErr != nil {
			return closeErr
		}
	} else if err != nil {
		return err
	}
	if len(seed) != ed25519.SeedSize {
		return errors.New("invalid signing seed")
	}
	fmt.Println(base64.RawURLEncoding.EncodeToString(ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)))
	return nil
}

func serve(s activationServer, args []string) error {
	opts := flag.NewFlagSet("serve", flag.ContinueOnError)
	listen := opts.String("listen", "", "IPv4 overlay address and port")
	if err := opts.Parse(args); err != nil {
		return err
	}
	endpoint, err := netip.ParseAddrPort(*listen)
	if err != nil || opts.NArg() != 0 || !allowedIP(endpoint.Addr()) || endpoint.Port() == 0 {
		return errors.New("set --listen to this server's Tailscale or 10.x overlay IPv4 address and port (127.0.0.1 is available for local tests)")
	}
	listener, err := net.Listen("tcp4", endpoint.String())
	if err != nil {
		return err
	}
	fmt.Println("Activation server listening on", listener.Addr())
	server := &http.Server{Handler: s.handler(), ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 8 * time.Second, WriteTimeout: 8 * time.Second, IdleTimeout: 20 * time.Second, MaxHeaderBytes: 8192}
	return server.Serve(listener)
}

func allowedIP(ip netip.Addr) bool {
	if !ip.Is4() {
		return false
	}
	b := ip.As4()
	return ip == netip.MustParseAddr("127.0.0.1") || b[0] == 10 || b[0] == 100 && b[1] >= 64 && b[1] < 128
}

func keys(db *sql.DB, args []string) error {
	if len(args) < 1 {
		return errors.New("choose keys generate, list, or revoke")
	}
	switch args[0] {
	case "generate":
		opts := flag.NewFlagSet("keys generate", flag.ContinueOnError)
		count := opts.Int("count", 1, "number of keys")
		note := opts.String("note", "", "batch note")
		if err := opts.Parse(args[1:]); err != nil {
			return err
		}
		if *count < 1 || *count > 1000 || opts.NArg() != 0 || len(*note) > 256 {
			return errors.New("invalid key count or note")
		}
		tx, err := db.Begin()
		if err != nil {
			return err
		}
		defer tx.Rollback()
		generated := make([]string, 0, *count)
		for len(generated) < *count {
			key, err := newKey()
			if err != nil {
				return err
			}
			if _, err = tx.Exec(`INSERT INTO activation_keys(digest,note) VALUES (?,?)`, digest(key), *note); err != nil {
				return errors.New("could not generate the key batch")
			}
			generated = append(generated, key)
		}
		if err = tx.Commit(); err != nil {
			return err
		}
		for _, key := range generated {
			fmt.Println(key)
		}
		return nil
	case "list":
		if len(args) != 1 {
			break
		}
		rows, err := db.Query(`SELECT id,note,COALESCE(machine_hash,''),revoked FROM activation_keys ORDER BY id`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var id int64
			var note, device string
			var revoked bool
			if err = rows.Scan(&id, &note, &device, &revoked); err != nil {
				return err
			}
			status := "unused"
			if device != "" {
				status = "used"
			}
			if revoked {
				status = "revoked"
			}
			fmt.Printf("%d\t%s\t%s\t%q\n", id, status, device, note)
		}
		return rows.Err()
	case "revoke":
		if len(args) != 2 {
			break
		}
		key, ok := normalizeKey(args[1])
		if !ok {
			return errors.New("invalid key format")
		}
		result, err := db.Exec(`UPDATE activation_keys SET revoked=1 WHERE digest=? AND issued_at IS NULL AND revoked=0`, digest(key))
		if err != nil {
			return err
		}
		if n, _ := result.RowsAffected(); n != 1 {
			return errors.New("no unused key matched")
		}
		fmt.Println("Key revoked")
		return nil
	}
	return errors.New("choose keys generate, list, or revoke")
}

func devices(db *sql.DB, args []string) error {
	if len(args) == 1 && args[0] == "list" {
		rows, err := db.Query(`SELECT a.machine_hash,MAX(a.issued_at),r.machine_hash IS NOT NULL
   FROM activation_keys a LEFT JOIN revoked_devices r ON a.machine_hash=r.machine_hash
   WHERE a.issued_at IS NOT NULL GROUP BY a.machine_hash ORDER BY MAX(a.issued_at) DESC`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var machine string
			var timestamp int64
			var revoked bool
			if err = rows.Scan(&machine, &timestamp, &revoked); err != nil {
				return err
			}
			fmt.Printf("%s\t%s\trevoked=%t\n", machine, time.Unix(timestamp, 0).UTC().Format(time.RFC3339), revoked)
		}
		return rows.Err()
	}
	if len(args) == 2 && args[0] == "revoke" && hexDigest.MatchString(args[1]) {
		result, err := db.Exec(`INSERT OR IGNORE INTO revoked_devices(machine_hash)
   SELECT DISTINCT machine_hash FROM activation_keys WHERE machine_hash=?`, args[1])
		if err != nil {
			return err
		}
		if n, _ := result.RowsAffected(); n != 1 {
			return errors.New("device not found or already revoked")
		}
		fmt.Println("Device revoked")
		return nil
	}
	return errors.New("choose devices list or devices revoke <machine hash>")
}
