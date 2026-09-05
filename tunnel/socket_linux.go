package main

import (
	"errors"
	"log"
	"net"
	"sync"
	"syscall"
	"time"
)

var unsupportedTimeout sync.Once

func setUserTimeout(conn *net.TCPConn, d time.Duration) error {
	if d == 0 {
		return nil
	}
	raw, err := conn.SyscallConn()
	if err != nil {
		return err
	}
	var optionErr error
	err = raw.Control(func(fd uintptr) {
		optionErr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_TCP, 18, int((d+time.Millisecond-1)/time.Millisecond))
	})
	if err != nil {
		return err
	}
	if errors.Is(optionErr, syscall.ENOPROTOOPT) {
		if ok, checkErr := conn.MultipathTCP(); checkErr == nil && ok {
			unsupportedTimeout.Do(func() {
				log.Print("kernel does not support TCP_USER_TIMEOUT on MPTCP; application write/idle/age limits remain active")
			})
			return nil
		}
	}
	return optionErr
}
