#!/usr/bin/env bash
# Publish the starch site and the current ISO.
#
#     ./tools/deploy-web.sh              # site + the ISO, if it changed
#     ./tools/deploy-web.sh --no-iso     # site only, seconds rather than minutes
#     ./tools/deploy-web.sh --force-iso  # re-upload the ISO even if unchanged
#     ./tools/deploy-web.sh --dry-run    # print every AWS call, make none
#
# Idempotent: it creates what is missing and updates what is not, so running it
# again after editing a page is the normal way to publish.
#
# It does not touch bucket access. ./tools/deploy-cdn.sh owns that — it makes
# the bucket private and readable only through CloudFront — and a publish
# script that also set a policy would quietly undo the lockdown every time
# someone fixed a typo. Two scripts writing one policy is a bug waiting to
# happen, so only one of them writes it.
set -euo pipefail

BUCKET="${STARCH_BUCKET:-starch-downloads-133313813536}"
REGION="${STARCH_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"
HOST="${STARCH_HOST:-starch.pbcs.io}"

# Releases are versioned by month, because rebuilds are monthly: the key is
# starch-2026.09-x86_64.iso, derived from the ISO's own filename, so each
# release keeps its own URL and an older one stays downloadable.
#
# starch-latest-x86_64.iso is kept beside it as a stable name for anything
# that wants "whatever is current" — made with a server-side copy, so it costs
# one API call rather than a second three-gigabyte upload.
LATEST_KEY="starch-latest-x86_64.iso"

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WEB="$HERE/web"
OUT="$HERE/out"

DRY=0
DO_ISO=1
FORCE_ISO=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY=1 ;;
        --no-iso)    DO_ISO=0 ;;
        --force-iso) FORCE_ISO=1 ;;
        -h|--help)   sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg (try --dry-run, --no-iso, --force-iso)" >&2; exit 2 ;;
    esac
done

C_B=$'\e[1;34m'; C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_R=$'\e[1;31m'; C_0=$'\e[0m'
step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '\n%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
run()  { if [[ $DRY -eq 1 ]]; then printf '    %s[dry-run]%s %s\n' "$C_Y" "$C_0" "$*"; else "$@"; fi; }

# ── preflight ────────────────────────────────────────────────────────────────
step "Checking prerequisites"
command -v aws >/dev/null || die "the aws CLI is not installed"
[[ -f $WEB/index.html ]] || die "no site at $WEB"
aws sts get-caller-identity >/dev/null 2>&1 \
    || die "the aws CLI has no working credentials — run: aws configure"
account="$(aws sts get-caller-identity --query Account --output text)"
ok "aws CLI, account $account, region $REGION"

if [[ $DO_ISO -eq 1 ]]; then
    # Newest by mtime rather than by name: a rebuild on the same day reuses the
    # filename, so sorting by name would publish yesterday's image.
    iso="$(ls -t "$OUT"/*.iso 2>/dev/null | head -1 || true)"
    [[ -n $iso ]] || die "no ISO in $OUT — build one first, or pass --no-iso"

    # starch-2026.09.26-x86_64.iso -> 2026.09. The build stamps a full date;
    # the release is the month, so two builds in one month replace each other
    # rather than littering the bucket with 3GB objects.
    VERSION="$(basename "$iso" | sed -nE 's/^starch-([0-9]{4})\.([0-9]{2})\..*/\1.\2/p')"
    [[ -n $VERSION ]] || die "cannot read a version from $(basename "$iso")"
    ISO_KEY="starch-${VERSION}-x86_64.iso"
    ok "ISO: $(basename "$iso") ($(du -h "$iso" | cut -f1)) — release $VERSION"
fi

# --no-iso still has to know what the page should link to.
if [[ -z ${ISO_KEY:-} ]]; then
    ISO_KEY="$(aws s3 ls "s3://$BUCKET/" 2>/dev/null \
        | awk '{print $4}' | grep -E '^starch-[0-9]{4}\.[0-9]{2}-x86_64\.iso$' \
        | sort | tail -1)"
    [[ -n $ISO_KEY ]] || ISO_KEY="$LATEST_KEY"
    VERSION="$(sed -nE 's/^starch-([0-9]{4}\.[0-9]{2})-x86_64\.iso$/\1/p' <<<"$ISO_KEY")"
fi

# ── the bucket ───────────────────────────────────────────────────────────────
step "Bucket"
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    ok "s3://$BUCKET"
else
    # us-east-1 is the one region that must NOT be given a LocationConstraint;
    # passing it there is an InvalidLocationConstraint error.
    if [[ $REGION == us-east-1 ]]; then
        run aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
    else
        run aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
            --create-bucket-configuration "LocationConstraint=$REGION"
    fi
    ok "created s3://$BUCKET"
    warn "new bucket — run ./tools/deploy-cdn.sh to publish it over https"
fi

# ── the ISO ──────────────────────────────────────────────────────────────────
if [[ $DO_ISO -eq 1 ]]; then
    step "ISO"
    local_sum=""
    if [[ $DRY -eq 0 ]]; then
        local_sum="$(sha256sum "$iso" | cut -d' ' -f1)"
    fi

    # Compare against the checksum uploaded beside the last one rather than
    # re-sending three gigabytes to find out nothing changed. S3's ETag is no
    # use for this: a multipart upload's ETag is not the file's MD5.
    remote_sum=""
    if [[ $FORCE_ISO -eq 0 && $DRY -eq 0 ]]; then
        remote_sum="$(aws s3 cp "s3://$BUCKET/$ISO_KEY.sha256" - 2>/dev/null | cut -d' ' -f1 || true)"
    fi

    if [[ -n $local_sum && $local_sum == "$remote_sum" ]]; then
        ok "unchanged — skipping the upload (--force-iso overrides)"
    else
        [[ $FORCE_ISO -eq 1 ]] && warn "--force-iso: uploading even though it may be unchanged"
        warn "uploading $(du -h "$iso" | cut -f1) — this is the slow part"
        run aws s3 cp "$iso" "s3://$BUCKET/$ISO_KEY" \
            --content-type application/octet-stream \
            --cache-control "public, max-age=86400" \
            --only-show-errors
        ok "s3://$BUCKET/$ISO_KEY"

        # Written after the ISO, never before: if the upload fails, the old
        # checksum must stay, or the next run would skip a broken object.
        if [[ $DRY -eq 1 ]]; then
            printf '    %s[dry-run]%s upload the sha256 beside it\n' "$C_Y" "$C_0"
        else
            printf '%s  %s\n' "$local_sum" "$ISO_KEY" > /tmp/starch-iso.sha256
            aws s3 cp /tmp/starch-iso.sha256 "s3://$BUCKET/$ISO_KEY.sha256" \
                --content-type text/plain --cache-control "public, max-age=300" --only-show-errors
            rm -f /tmp/starch-iso.sha256
            ok "sha256 $local_sum"
        fi

        # Server-side: S3 copies it internally, so "latest" costs an API call
        # rather than another three gigabytes over the wire.
        run aws s3 cp "s3://$BUCKET/$ISO_KEY" "s3://$BUCKET/$LATEST_KEY" \
            --content-type application/octet-stream \
            --cache-control "public, max-age=3600" --only-show-errors
        run aws s3 cp "s3://$BUCKET/$ISO_KEY.sha256" "s3://$BUCKET/$LATEST_KEY.sha256" \
            --content-type text/plain --cache-control "public, max-age=300" --only-show-errors
        ok "$LATEST_KEY points at $VERSION"
    fi
fi

# ── the site ─────────────────────────────────────────────────────────────────
# The repo keeps the placeholder URL so index.html stays a template; the real
# one is substituted into a copy at deploy time. Editing the committed file to
# publish would mean the repo never matches what is live.
step "Site"
iso_url="https://$HOST/$ISO_KEY"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
cp -r "$WEB"/. "$stage"/
sum_placeholder="https://REPLACE-ME.s3.amazonaws.com/starch-x86_64.iso.sha256"
placeholder="https://REPLACE-ME.s3.amazonaws.com/starch-x86_64.iso"
if grep -q "$placeholder" "$stage/index.html"; then
    # The checksum link first: it contains the ISO URL as a prefix, so
    # replacing the shorter string first would leave "…iso.sha256" mangled.
    sed -i "s|$sum_placeholder|$iso_url.sha256|g" "$stage/index.html"
    sed -i "s|$placeholder|$iso_url|g" "$stage/index.html"
    ok "download links point at $iso_url"
else
    warn "placeholder not found in index.html — links left as they are"
fi
if grep -q "RELEASE-VERSION" "$stage/index.html"; then
    sed -i "s|RELEASE-VERSION|${VERSION:-current}|g" "$stage/index.html"
    ok "page labelled release ${VERSION:-current}"
fi

# Assets get a long cache; the page itself must not be cached, or an edit is
# invisible until it expires.
run aws s3 sync "$stage/assets/" "s3://$BUCKET/assets/" \
    --cache-control "public, max-age=604800" --only-show-errors --delete
run aws s3 cp "$stage/style.css" "s3://$BUCKET/style.css" \
    --content-type "text/css" --cache-control "public, max-age=3600" --only-show-errors
run aws s3 cp "$stage/index.html" "s3://$BUCKET/index.html" \
    --content-type "text/html; charset=utf-8" --cache-control "no-cache" --only-show-errors
ok "site uploaded"

# ── CloudFront ───────────────────────────────────────────────────────────────
# Uploading to S3 is not publishing. CloudFront serves what it cached until
# told otherwise, so without this an edited page stays the old one at every
# edge and the deploy looks like it silently failed.
step "CloudFront"
dist="$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(Aliases.Items || \`[]\`, '$HOST')].Id | [0]" \
    --output text 2>/dev/null || echo None)"

if [[ -z $dist || $dist == None ]]; then
    warn "no distribution serving $HOST — run ./tools/deploy-cdn.sh"
    site_url="s3://$BUCKET (not published over https yet)"
else
    # Invalidating /* costs nothing up to 1000 paths a month and avoids having
    # to reason about exactly which files moved.
    run aws cloudfront create-invalidation --distribution-id "$dist" --paths "/*" >/dev/null
    ok "invalidated $dist"
    site_url="https://$HOST"
fi

# ── done ─────────────────────────────────────────────────────────────────────
step "Done"
cat <<EOF

  Site      ${site_url}
  ISO       ${iso_url}
  Checksum  ${iso_url}.sha256
  Latest    https://${HOST}/${LATEST_KEY}

  Re-run after editing the page. The ISO is skipped when unchanged, so this
  is cheap; --no-iso skips the check as well.

EOF
