#!/usr/bin/env bash

[ ! -f ca.key ] && \
    openssl genrsa -out ca.key 4096
[ ! -f ca.crt ] && \
    openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -subj "/CN=IceWarp Cloutcd VPN Root CA" -out ca.crt

[ ! -f server.key ] && \
    openssl genrsa -out server.key 2048
[ ! -f server.csr ] && \
    openssl req -new -key server.key -subj "/CN=vpn.example.com" -out server.csr
[ ! -f server.crt ] && \
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 825 -sha256