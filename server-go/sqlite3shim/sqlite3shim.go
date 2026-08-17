// Package sqlite3shim registers the pure-Go modernc sqlite driver under the
// legacy "sqlite3" name that whatsmeow's sqlstore.New uses. This keeps the
// whole build CGO-free (no mattn/go-sqlite3 cgo), so the Linux deploy binary
// is static and needs no toolchain on the VPS.
package sqlite3shim

import (
	"database/sql"

	"modernc.org/sqlite"
)

func init() {
	sql.Register("sqlite3", &sqlite.Driver{})
}
