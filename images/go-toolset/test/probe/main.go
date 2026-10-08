// Probe for ubi9-go-toolset, built by images/go-toolset/test twice (static
// and with cgo) and run on ubi9-micro. Prints one line per check:
// "PASS <check>: <what it saw>" or "FAIL <check>: <error>", and exits 1
// when any check failed.
//
// Go carries its own cryptography; it does not use micro's OpenSSL. The TLS
// check proves that a Go binary finds micro's CA bundle and time zones.
package main

import (
  "fmt"
  "net/http"
  "os"
  "time"
)

var failed = false

func check(name string, body func() (string, error)) {
  seen, err := body()
  if err != nil {
    failed = true
    fmt.Printf("FAIL %s: %v\n", name, err)
    return
  }
  fmt.Printf("PASS %s: %s\n", name, seen)
}

func main() {
  check("runs as", func() (string, error) {
    return fmt.Sprintf("uid %d", os.Getuid()), nil
  })
  check("linking", func() (string, error) {
    return linking, nil
  })
  check("time zones", func() (string, error) {
    chicago, err := time.LoadLocation("America/Chicago")
    if err != nil {
      return "", err
    }
    noon := time.Date(2026, 7, 1, 12, 0, 0, 0, time.UTC)
    return noon.In(chicago).Format("15:04"), nil
  })
  check("HTTPS to github.com", func() (string, error) {
    client := http.Client{Timeout: 20 * time.Second}
    response, err := client.Get("https://github.com/")
    if err != nil {
      return "", err
    }
    response.Body.Close()
    return fmt.Sprintf("HTTP %d", response.StatusCode), nil
  })
  if failed {
    os.Exit(1)
  }
}
