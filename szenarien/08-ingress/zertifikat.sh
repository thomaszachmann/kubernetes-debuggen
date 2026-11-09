#!/usr/bin/env bash
# Erzeugt eine Labor-CA und ein Server-Zertifikat für shop.dbg08.example.
#   ./zertifikat.sh gueltig      Zertifikat gilt 30 Tage ab jetzt
#   ./zertifikat.sh abgelaufen   Zertifikat ist seit 2025 abgelaufen
# Ergebnis in szenarien/08-ingress/tls/: ca.crt, shop.crt, shop.key
# Braucht OpenSSL 3.4 oder neuer (-not_before/-not_after), z. B. aus Homebrew.
set -euo pipefail

modus="${1:-}"
host="shop.dbg08.example"
dir="$(cd "$(dirname "$0")" && pwd)/tls"

case "$modus" in
  gueltig | abgelaufen) ;;
  *)
    echo "Aufruf: $0 gueltig|abgelaufen" >&2
    exit 2
    ;;
esac

if ! openssl x509 -help 2>&1 | grep -q -- '-not_after'; then
  echo "Fehler: $(openssl version) kennt -not_after nicht, OpenSSL 3.4+ nötig." >&2
  exit 1
fi

mkdir -p "$dir"
cd "$dir"

# Labor-CA nur einmal anlegen, damit curl --cacert gleich bleibt.
if [[ ! -f ca.key ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt \
    -days 365 -subj "/CN=dbg-08 Labor-CA" 2>/dev/null
fi

openssl req -newkey rsa:2048 -nodes -keyout shop.key -out shop.csr \
  -subj "/CN=$host" 2>/dev/null

printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$host" > shop.ext

if [[ "$modus" == "gueltig" ]]; then
  zeit=(-days 30)
else
  zeit=(-not_before 20250101000000Z -not_after 20250201000000Z)
fi

openssl x509 -req -in shop.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out shop.crt -extfile shop.ext "${zeit[@]}" 2>/dev/null

rm -f shop.csr shop.ext
openssl x509 -in shop.crt -noout -subject -enddate
