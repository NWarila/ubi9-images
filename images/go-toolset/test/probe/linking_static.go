//go:build !cgo

package main

// Built with CGO_ENABLED=0: a static binary with no C library.
const linking = "static"
