#!/usr/bin/env bash
# Runs the trigger against Dokku's stock vhost template and against shapes it must refuse.
# The rendered vhosts are checked on a host by `dokku proxy:build-config`, which runs `nginx -t`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIGGER="$HERE/../nginx-app-template-source"
# Under $HOME rather than /tmp so the docker VM can mount it.
ROOT="$(mktemp -d "$HOME/.dokku-no-http2-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export PLUGIN_AVAILABLE_PATH="$ROOT/plugins" NO_HTTP2_DATA_DIR="$ROOT/data"
TPL="$PLUGIN_AVAILABLE_PATH/nginx-vhosts/templates/nginx.conf.sigil"
mkdir -p "$(dirname "$TPL")"
FAILED=0
HTTP2='^[[:space:]]*listen[[:space:]][^;]*http2|^[[:space:]]*http2[[:space:]]+on'

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; FAILED=1; }

for fixture in "$HERE"/fixtures/nginx.conf.sigil.*; do
  name="stock $(basename "$fixture")"
  before=$FAILED FAILED=0
  cp "$fixture" "$TPL"
  out="$("$TRIGGER" app app-config)" || { fail "$name: trigger failed"; continue; }
  [[ "$out" == "$NO_HTTP2_DATA_DIR/nginx.conf.sigil" ]] || fail "$name: printed '$out'"
  grep -qE "$HTTP2" "$out" && fail "$name: HTTP/2 left in the output"
  # Only http2 lines may differ: every removed line mentions http2, every added line is a listen.
  removed="$(diff "$fixture" "$out" | grep '^<' | grep -vc 'http2' || true)"
  added="$(diff "$fixture" "$out" | grep '^>' | grep -vcE '^>[[:space:]]+listen[[:space:]]' || true)"
  [[ "$removed" == 0 && "$added" == 0 ]] || fail "$name: unexpected edits (removed=$removed added=$added)"
  grep -q 'http2_push_preload' "$out" || fail "$name: unrelated http2_push_preload line touched"
  [[ $FAILED == 0 ]] && pass "$name"
  [[ $before == 0 ]] || FAILED=1
done

name="other template types are left to Dokku"
if out="$("$TRIGGER" app hsts-config)" && [[ -z "$out" ]]; then pass "$name"; else fail "$name"; fi

for pair in '  listen 443 ssl http2 reuseport;|  listen 443 ssl reuseport;' '  listen 443 http2 ssl;|  listen 443 ssl;'; do
  shape="${pair%%|*}" want="${pair#*|}"
  name="strips '$shape'"
  printf 'server {\n%s\n}\n' "$shape" >"$TPL"
  if out="$("$TRIGGER" app app-config)" && [[ "$(sed -n 2p "$out")" == "$want" ]]; then pass "$name"; else fail "$name"; fi
done

for shape in '  http2   on ;' '  listen 443 ssl {{ if $.H2 }}http2{{ end }};' '  listen 443 ssl{{ if $.TLS }} http2{{ end }};'; do
  name="refuses '$shape'"
  printf 'server {\n%s\n}\n' "$shape" >"$TPL"
  if out="$("$TRIGGER" app app-config 2>/dev/null)"; then
    fail "$name: exited 0 and printed '$out'"
  else
    if [[ -z "$out" ]]; then pass "$name"; else fail "$name: printed '$out'"; fi
  fi
done

exit "$FAILED"
