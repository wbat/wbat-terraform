#!/bin/bash
# Read the backup archives in S3 back, to establish that they are archives.
#
# Why this exists
# ---------------
# Until 2026-09-07 the rule for deleting a local backup was: upload it, run
# `rclone check --checksum --one-way` against the S3 copy, delete the local file once S3
# is confirmed to hold the same bytes. That rule is sound about bytes and says nothing
# about completeness. A tellerstec backup killed mid-archive by the free-space watchdog
# produced a 20.02 GiB fragment; the hook uploaded it, checksummed it, was correctly told
# the bytes matched, and deleted the only other copy. See
# aws/docs/2026-09-06-primary-outage.md.
#
# all_backups_post.sh now reads every archive before uploading it, so new objects cannot
# reach S3 that way. That fix is forward-looking: every object already in the bucket was
# admitted under the old rule. This script is how you check them.
#
# What it does, and what each test proves
# ---------------------------------------
#   --full    Stream the object out of S3, decompress it, and parse the tar inside it.
#             Proves the object is a complete, well-formed archive whose member list can
#             be read from the first byte to the end-of-archive marker. Costs the whole
#             object in egress. This is the only test that settles the question for
#             .tar.zst, because zstd has no trailer you can read without decompressing
#             everything before it.
#
#   --quick   For .tar.gz only: a ranged GET of the last 8 bytes. A gzip member ends with
#             CRC32 then ISIZE, the uncompressed length modulo 2^32. A tar is always a
#             whole number of 512-byte blocks and 2^32 is a multiple of 512, so an intact
#             .tar.gz has ISIZE congruent to 0 mod 512 whatever its true size. Truncate
#             the file and those four bytes become deflate payload, which lands on a
#             multiple of 512 with probability 1/512.
#
#             So --quick is a necessary condition, not a sufficient one, for about eight
#             bytes instead of gigabytes. It catches truncation ~99.8% of the time per
#             object. It cannot see corruption in the middle of the stream, it does not
#             check the CRC, and it says nothing about whether the tar holds a plausible
#             account. On the 2026-09-08 sweep it agreed with --full on all 627 objects
#             that got both tests, and flagged every one of the 15 truncated .tar.gz
#             objects the full reads went on to confirm.
#
# Three verdicts, not two. READABLE is a whole archive with members. EMPTY is a whole
# archive with none -- sysbk archiving a path that does not exist on this host produces a
# valid 45-byte .tar.gz, and there are 379 of them in the bucket. Calling those damaged
# would bury the real failures. UNREADABLE is the one that matters.
#
# Read-only. Nothing here writes to S3 or to the host; renaming a bad object is a
# deliberate, separate decision.
#
# Usage:
#   ./verify-s3-archives.sh --self-test                     # offline, no credentials
#   ./verify-s3-archives.sh --quick --prefix server/2026-
#   ./verify-s3-archives.sh --full  --prefix server/2026-09-07/
#   ./verify-s3-archives.sh --full  --prefix server/ --max-bytes 20000000000
set -uo pipefail

BUCKET="${BUCKET:-wbat-tellerstech-directadmin-backups-708113892725}"
PREFIX=""
MODE=""
MAX_BYTES=0
OUT=""

die() {
  echo "$*" >&2
  exit 2
}

usage() {
  sed -n '/^# Usage:/,/^set -u/p' "$0" | sed 's/^# \{0,1\}//;$d'
  exit "${1:-0}"
}

while (($#)); do
  case "$1" in
    --full | --quick) MODE="${1#--}" ;;
    --self-test) MODE=self-test ;;
    --prefix) PREFIX="${2:-}" && shift ;;
    --bucket) BUCKET="${2:-}" && shift ;;
    --out) OUT="${2:-}" && shift ;;
    # Skip objects larger than this, so a sweep can be scoped to what the egress budget
    # allows without hand-editing a list of keys.
    --max-bytes) MAX_BYTES="${2:-0}" && shift ;;
    -h | --help) usage 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
[[ -n "$MODE" ]] || usage 2

# ---------------------------------------------------------------------------
# The two tests.
# ---------------------------------------------------------------------------

decompressor_for() {
  case "$1" in
    *.tar.zst | *.tzst | *.tar.zst.TRUNCATED-DO-NOT-RESTORE) echo "zstd -dc" ;;
    *.tar.gz | *.tgz | *.tar.gz.TRUNCATED-DO-NOT-RESTORE) echo "gzip -dc" ;;
    *) echo "" ;;
  esac
}

# Reads whatever is on stdin and prints "<verdict> <member-count>".
#
# dd is on the compressed side so the byte count is an independent assertion that the
# whole object was consumed: `tar -t` reads its input to the end of the stream, so a short
# count means the pipeline stopped early rather than the archive being read and accepted.
read_stream() {
  local decomp="$1" expect="$2" ddf errf rc members read_bytes
  ddf="$(mktemp)"
  errf="$(mktemp)"
  dd bs=4M 2>"$ddf" | $decomp 2>"$errf" | tar -tf - 2>>"$errf" | grep -c . >/tmp/.vsa_members
  rc=("${PIPESTATUS[@]}")
  members="$(cat /tmp/.vsa_members 2>/dev/null || echo 0)"
  read_bytes="$(sed -n 's/^\([0-9]*\) bytes.*/\1/p' "$ddf" | tail -1)"
  read_bytes="${read_bytes:-0}"

  if [[ "${rc[0]}" != 0 || "${rc[1]}" != 0 || "${rc[2]}" != 0 ]] \
    || [[ -n "$expect" && "$read_bytes" != "$expect" ]]; then
    printf 'UNREADABLE\t%s\t%s\n' "${members:-0}" \
      "$(tr '\n' ' ' <"$errf" | tr -s ' ' | cut -c1-200)"
  elif ((members > 0)); then
    printf 'READABLE\t%s\t\n' "$members"
  else
    printf 'EMPTY\t0\t\n'
  fi
  rm -f "$ddf" "$errf" /tmp/.vsa_members
}

test_full() {
  local key="$1" size="$2" decomp
  decomp="$(decompressor_for "$key")"
  [[ -n "$decomp" ]] || {
    printf 'SKIPPED\t0\tnot a container this knows how to open\n'
    return
  }
  aws s3 cp "s3://${BUCKET}/${key}" - 2>/dev/null | read_stream "$decomp" "$size"
}

test_quick() {
  local key="$1" size="$2" tmp
  case "$key" in
    *.tar.gz | *.tgz | *.tar.gz.TRUNCATED-DO-NOT-RESTORE) ;;
    *)
      printf 'SKIPPED\t0\t--quick only applies to gzip; use --full\n'
      return
      ;;
  esac
  ((size >= 18)) || {
    printf 'UNREADABLE\t0\tshorter than a gzip header plus trailer\n'
    return
  }
  tmp="$(mktemp)"
  if ! aws s3api get-object --bucket "$BUCKET" --key "$key" \
    --range "bytes=$((size - 8))-$((size - 1))" "$tmp" >/dev/null 2>&1; then
    printf 'ERROR\t0\tranged GET failed\n'
    rm -f "$tmp"
    return
  fi
  python3 - "$tmp" <<'PY'
import struct, sys
crc, isize = struct.unpack('<II', open(sys.argv[1], 'rb').read(8))
ok = isize > 0 and isize % 512 == 0
print(f"{'TRAILER-OK' if ok else 'UNREADABLE'}\t0\tcrc32={crc:08x} isize={isize} isize%512={isize % 512}")
PY
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Non-vacuity. A test that cannot fail is worse than no test, and the failure this whole
# exercise is about is one that passed a check nobody had confirmed could fail.
# ---------------------------------------------------------------------------

self_test() {
  local d rc=0 v
  d="$(mktemp -d)"
  mkdir -p "$d/src/example.com/email"
  head -c 3000000 /dev/urandom >"$d/src/example.com/blob"
  echo present >"$d/src/example.com/email/passwd"

  tar -cf - -C "$d/src" . | zstd -q -o "$d/good.tar.zst"
  tar -cf - -C "$d/src" . | gzip -c >"$d/good.tar.gz"
  tar -cf - -C "$d/empty-src" . 2>/dev/null || tar -cf "$d/empty.tar" -T /dev/null
  gzip -c <"$d/empty.tar" >"$d/empty.tar.gz"
  for f in good.tar.zst good.tar.gz; do
    head -c "$(($(stat -c%s "$d/$f") * 60 / 100))" "$d/$f" >"$d/trunc.${f#good.}"
  done

  check() { # label file expected-verdict
    local got
    got="$(read_stream "$(decompressor_for "$2")" "$(stat -c%s "$2")" <"$2" | cut -f1)"
    if [[ "$got" == "$3" ]]; then
      printf '  ok    %-34s %s\n' "$1" "$got"
    else
      printf '  FAIL  %-34s got %s, wanted %s\n' "$1" "$got" "$3"
      rc=1
    fi
  }
  check "whole .tar.zst reads clean" "$d/good.tar.zst" READABLE
  check "truncated .tar.zst is caught" "$d/trunc.tar.zst" UNREADABLE
  check "whole .tar.gz reads clean" "$d/good.tar.gz" READABLE
  check "truncated .tar.gz is caught" "$d/trunc.tar.gz" UNREADABLE
  check "empty-but-valid .tar.gz is EMPTY" "$d/empty.tar.gz" EMPTY

  # The cheap test has to fail on the truncated file too, or a --quick sweep is decorative.
  local isz
  for f in good trunc; do
    isz="$(python3 -c "
import struct,sys
print(struct.unpack('<II', open(sys.argv[1],'rb').read()[-8:])[1] % 512)" "$d/$f.tar.gz")"
    if [[ "$f" == good && "$isz" == 0 ]] || [[ "$f" == trunc && "$isz" != 0 ]]; then
      printf '  ok    %-34s isize%%512=%s\n' "trailer test on ${f} .tar.gz" "$isz"
    else
      printf '  FAIL  %-34s isize%%512=%s\n' "trailer test on ${f} .tar.gz" "$isz"
      rc=1
    fi
  done

  rm -rf "$d"
  ((rc == 0)) && echo "self-test passed" || echo "self-test FAILED"
  return "$rc"
}

if [[ "$MODE" == self-test ]]; then
  self_test
  exit $?
fi

# ---------------------------------------------------------------------------
# Sweep.
# ---------------------------------------------------------------------------

command -v aws >/dev/null 2>&1 || die "aws CLI not found"
listing="$(mktemp)"
aws s3api list-objects-v2 --bucket "$BUCKET" ${PREFIX:+--prefix "$PREFIX"} \
  --query 'Contents[].[Key,Size]' --output text >"$listing" \
  || die "could not list s3://${BUCKET}/${PREFIX}"

declare -A tally=()
results="${OUT:-$(mktemp)}"
: >"$results"

while IFS=$'\t' read -r key size; do
  [[ -n "$key" ]] || continue
  case "$key" in *.md5 | *.txt | *.sh) continue ;; esac
  if ((MAX_BYTES > 0)) && ((size > MAX_BYTES)); then
    printf '%s\t%s\tSKIPPED\t0\tlarger than --max-bytes\n' "$key" "$size" >>"$results"
    tally[SKIPPED]=$((${tally[SKIPPED]:-0} + 1))
    continue
  fi
  line="$([[ "$MODE" == full ]] && test_full "$key" "$size" || test_quick "$key" "$size")"
  verdict="$(cut -f1 <<<"$line")"
  tally[$verdict]=$((${tally[$verdict]:-0} + 1))
  printf '%s\t%s\t%s\n' "$key" "$size" "$line" >>"$results"
  printf '%-12s %s\n' "$verdict" "$key" >&2
done <"$listing"
rm -f "$listing"

echo >&2
echo "=== $MODE sweep of s3://${BUCKET}/${PREFIX} ===" >&2
for v in "${!tally[@]}"; do printf '  %-12s %d\n' "$v" "${tally[$v]}" >&2; done
[[ -n "$OUT" ]] && echo "  per-object results: $OUT" >&2

# Exit 1 if anything in the sweep could not be read, so this can gate a restore decision.
((${tally[UNREADABLE]:-0} == 0))
