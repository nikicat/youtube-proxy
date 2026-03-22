package main

import (
	"bufio"
	"crypto/tls"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"
)

func relay(a, b net.Conn) {
	done := make(chan struct{}, 2)
	go func() {
		io.Copy(b, a)
		done <- struct{}{}
	}()
	go func() {
		io.Copy(a, b)
		done <- struct{}{}
	}()
	<-done
}

func handleHTTPS(conn net.Conn) {
	defer conn.Close()

	br := bufio.NewReader(conn)
	req, err := http.ReadRequest(br)
	if err != nil {
		return
	}

	if req.Method != http.MethodConnect {
		fmt.Fprintf(conn, "HTTP/1.1 405 Method Not Allowed\r\n\r\n")
		return
	}

	dest := req.Host
	if _, _, err := net.SplitHostPort(dest); err != nil {
		dest = net.JoinHostPort(dest, "443")
	}

	target, err := net.DialTimeout("tcp", dest, 10*time.Second)
	if err != nil {
		fmt.Fprintf(conn, "HTTP/1.1 502 Bad Gateway\r\n\r\n")
		return
	}
	defer target.Close()

	fmt.Fprintf(conn, "HTTP/1.1 200 Connection Established\r\n\r\n")
	relay(conn, target)
}

func handleSOCKS5(conn net.Conn) {
	defer conn.Close()

	br := bufio.NewReader(conn)

	// Auth negotiation
	ver, _ := br.ReadByte()
	if ver != 0x05 {
		return
	}
	nmethods, _ := br.ReadByte()
	methods := make([]byte, nmethods)
	io.ReadFull(br, methods)
	// Reply: no auth required
	conn.Write([]byte{0x05, 0x00})

	// Request
	header := make([]byte, 4)
	if _, err := io.ReadFull(br, header); err != nil {
		return
	}
	if header[0] != 0x05 || header[1] != 0x01 { // CONNECT only
		conn.Write([]byte{0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	var dest string
	switch header[3] {
	case 0x01: // IPv4
		addr := make([]byte, 4)
		io.ReadFull(br, addr)
		dest = net.IP(addr).String()
	case 0x03: // Domain
		domainLen, _ := br.ReadByte()
		domain := make([]byte, domainLen)
		io.ReadFull(br, domain)
		dest = string(domain)
	case 0x04: // IPv6
		addr := make([]byte, 16)
		io.ReadFull(br, addr)
		dest = "[" + net.IP(addr).String() + "]"
	default:
		conn.Write([]byte{0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	portBuf := make([]byte, 2)
	io.ReadFull(br, portBuf)
	port := binary.BigEndian.Uint16(portBuf)
	dest = net.JoinHostPort(dest, strconv.Itoa(int(port)))

	target, err := net.DialTimeout("tcp", dest, 10*time.Second)
	if err != nil {
		conn.Write([]byte{0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	defer target.Close()

	// Success reply
	conn.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
	relay(conn, target)
}

func usage() {
	fmt.Fprintf(os.Stderr, "Usage: %s <mode> <addr>\n", os.Args[0])
	fmt.Fprintf(os.Stderr, "  mode: https  - HTTPS CONNECT proxy (requires certs/proxy.crt and certs/proxy.key)\n")
	fmt.Fprintf(os.Stderr, "        http   - plain HTTP CONNECT proxy\n")
	fmt.Fprintf(os.Stderr, "        socks5 - SOCKS5 proxy\n")
	fmt.Fprintf(os.Stderr, "  addr: listen address (e.g. 0.0.0.0:8443)\n")
	os.Exit(1)
}

func main() {
	if len(os.Args) < 3 {
		usage()
	}

	mode := os.Args[1]
	addr := os.Args[2]

	switch mode {
	case "https":
		cert, err := tls.LoadX509KeyPair("certs/proxy.crt", "certs/proxy.key")
		if err != nil {
			log.Fatalf("Failed to load cert: %v", err)
		}
		listener, err := tls.Listen("tcp", addr, &tls.Config{
			Certificates: []tls.Certificate{cert},
			MinVersion:   tls.VersionTLS12,
		})
		if err != nil {
			log.Fatalf("Failed to listen: %v", err)
		}
		defer listener.Close()
		log.Printf("HTTPS CONNECT proxy listening on %s", addr)
		for {
			conn, err := listener.Accept()
			if err != nil {
				log.Printf("Accept error: %v", err)
				continue
			}
			go handleHTTPS(conn)
		}

	case "http":
		listener, err := net.Listen("tcp", addr)
		if err != nil {
			log.Fatalf("Failed to listen: %v", err)
		}
		defer listener.Close()
		log.Printf("HTTP CONNECT proxy listening on %s", addr)
		for {
			conn, err := listener.Accept()
			if err != nil {
				log.Printf("Accept error: %v", err)
				continue
			}
			go handleHTTPS(conn) // same handler, just no TLS wrapper
		}

	case "socks5":
		listener, err := net.Listen("tcp", addr)
		if err != nil {
			log.Fatalf("Failed to listen: %v", err)
		}
		defer listener.Close()
		log.Printf("SOCKS5 proxy listening on %s", addr)
		for {
			conn, err := listener.Accept()
			if err != nil {
				log.Printf("Accept error: %v", err)
				continue
			}
			go handleSOCKS5(conn)
		}

	default:
		usage()
	}
}
