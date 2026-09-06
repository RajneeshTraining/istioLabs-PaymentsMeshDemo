#!/usr/bin/env bash
set -e
mkdir -p tls
openssl req -x509 -nodes -newkey rsa:2048 -keyout tls/tls.key -out tls/tls.crt -days 2 -subj "/CN=api.example.test/O=ICA-Lab" -addext "subjectAltName=DNS:api.example.test"
kubectl -n security-labs create secret tls api-example-tls --key=tls/tls.key --cert=tls/tls.crt --dry-run=client -o yaml | kubectl apply -f -
