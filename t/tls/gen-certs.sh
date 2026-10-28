#!/bin/sh
# Makes a test CA, a second CA that does not sign the server, and a server
# certificate for localhost. The certificates are made in CI and are never
# committed.
set -eu

dir=${1:-t/tls/certs}
mkdir -p "$dir"
cd "$dir"

openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -subj "/CN=mongol-test-ca" -keyout ca.key -out ca.pem
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -subj "/CN=mongol-other-ca" -keyout other-ca.key -out other-ca.pem
openssl req -newkey rsa:2048 -nodes \
  -subj "/CN=localhost" -keyout server.key -out server.csr
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\n' >ext.cnf
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -days 2 -extfile ext.cnf -out server.crt
cat server.key server.crt >server.pem
chmod 644 ./*.pem
