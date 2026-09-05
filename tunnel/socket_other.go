//go:build !linux

package main

import (
	"errors"
	"net"
	"time"
)

func setUserTimeout(_ *net.TCPConn, d time.Duration) error {
	if d != 0 {
		return errors.New("TCP_USER_TIMEOUT requires Linux")
	}
	return nil
}
