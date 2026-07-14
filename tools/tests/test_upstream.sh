#!/usr/bin/env bash
# Tests for tools/lib/upstream.sh — run: bash tools/tests/test_upstream.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
source tools/lib/upstream.sh
fails=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — expected [$2] got [$3]"; fails=$((fails+1)); fi; }
tmp=$(mktemp -d)
cat > "$tmp/UPSTREAM.md" <<'EOF'
# Upstream Tracking
**Fork point / last synced:** 20abe1f90723391958e0b156293be91820178a5b (6.0.5-dev, 2026-07-14)
EOF
assert_eq "parse sha" "20abe1f90723391958e0b156293be91820178a5b" "$(parse_last_synced "$tmp/UPSTREAM.md")"
printf 'no sha here\n' > "$tmp/broken.md"
parse_last_synced "$tmp/broken.md" >/dev/null 2>&1
assert_eq "broken file exits 3" "3" "$?"
assert_eq "notify on growth"    "yes" "$(should_notify 12 5)"
assert_eq "silent when static"  "no"  "$(should_notify 5 5)"
assert_eq "silent when zero"    "no"  "$(should_notify 0 0)"
rm -rf "$tmp"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILURES"; exit 1; }
