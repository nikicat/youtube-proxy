#!/bin/sh
set -e

CERT_DIR="${CERT_DIR:-/certs}"
CERT_FILE="${CERT_FILE:-$CERT_DIR/proxy.crt}"
KEY_FILE="${KEY_FILE:-$CERT_DIR/proxy.key}"
PROXY_MODE="${PROXY_MODE:-https}"
PROXY_ADDR="${PROXY_ADDR:-0.0.0.0:443}"

if [ "$PROXY_MODE" = "https" ] && { [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; }; then
    CN="${CERT_CN:-proxy}"
    mkdir -p "$CERT_DIR"
    openssl req -x509 -newkey rsa:2048 \
        -keyout "$KEY_FILE" -out "$CERT_FILE" \
        -days 3650 -nodes \
        -subj "/CN=$CN" \
        -addext "subjectAltName=DNS:$CN"
    echo "Generated self-signed certificate for CN=$CN"
fi

export CERT_FILE KEY_FILE
exec /proxy "$PROXY_MODE" "$PROXY_ADDR"
