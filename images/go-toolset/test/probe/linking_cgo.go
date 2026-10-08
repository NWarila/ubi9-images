//go:build cgo

package main

// #include <stdlib.h>
import "C"

// Built with CGO_ENABLED=1: linked against micro's C library.
const linking = "cgo, linked against the C library"
