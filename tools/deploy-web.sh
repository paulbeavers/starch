#!/usr/bin/env bash
# Publish the starch site and the current ISO to an S3 static website.
#
#     ./tools/deploy-web.sh              # site + the newest ISO in out/
#     ./tools/deploy-web.sh --no-iso     # site only, seconds rather than minutes
#     ./tools/deploy-web.sh --dry-run    # print every AWS call, make none
#
# Idempotent: it creates what is missing and updates what is not, so running it
# again after editing a page is the normal way to publish.
#
# The bucket is deliberately public. It serves an ISO and a page describing it,
# both of which are meant to be downloaded by strangers — but "public bucket"
# is worth saying out loud, so the script says it and shows the policy it
# applies before applying it.
#
# Egress is the cost that surprises people: S3 charges for bytes out, and this
# ISO is ~3GB. A hundred downloads is roughly 300GB. If that ever matters, put
# CloudFront in front of the bucket; the page needs no change for it.
set -euo pipefail

BUCKET="${STARCH_BUCKET:-starch-downloads-133313813536}"
REGION="${STARCH_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"

# The site links this name, not the dated one, so the download URL is stable
# across releases and the page never needs editing to publish a new build.
ISO_KEY="starch-x86_64.iso"

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WEB="$HERE/web"
OUT="$HERE/out"

DRY=0
DO_ISO=1
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --no-iso)  DO_ISO=0 ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg (try --dry-run, --no-iso)" >&2; exit 2 ;;
    esac
done

C_B=$'\e[1;34m'; C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_R=$'\e[1;31m'; C_0=$'\e[0m'
step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '\n%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

run() {
    if [[ $DRY -eq 1 ]]; then
        printf '    %s[dry-run]%s %s\n' "$C_Y" "$C_0" "$*"
    else
        "$@"
    fi
}

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
    iso_size="$(du -h "$iso" | cut -f1)"
    ok "ISO: $(basename "$iso") ($iso_size)"
fi

# ── the bucket ───────────────────────────────────────────────────────────────
step "Bucket"
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    ok "s3://$BUCKET already exists"
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
fi

# ── public access ────────────────────────────────────────────────────────────
step "Public read"
warn "this bucket will be readable by anyone on the internet"
policy=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicReadGetObject",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::$BUCKET/*"
  }]
}
JSON
)
printf '%s\n' "$policy" | sed 's/^/      /'

# A bucket policy granting public read does nothing while Block Public Access
# is on, and it is on by default on every new bucket. Both halves are needed.
run aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false"
ok "block-public-policy off (ACLs stay blocked — the policy is what grants read)"

if [[ $DRY -eq 1 ]]; then
    printf '    %s[dry-run]%s aws s3api put-bucket-policy --bucket %s\n' "$C_Y" "$C_0" "$BUCKET"
else
    printf '%s' "$policy" | aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///dev/stdin
fi
ok "public read policy applied to objects only"

# ── static website hosting ───────────────────────────────────────────────────
step "Static website hosting"
run aws s3api put-bucket-website --bucket "$BUCKET" --website-configuration \
    '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"index.html"}}'
ok "index.html serves as both index and error document"

endpoint="http://$BUCKET.s3-website-$REGION.amazonaws.com"
[[ $REGION == us-east-1 ]] || endpoint="http://$BUCKET.s3-website.$REGION.amazonaws.com"
iso_url="https://$BUCKET.s3.amazonaws.com/$ISO_KEY"

# ── the ISO ──────────────────────────────────────────────────────────────────
if [[ $DO_ISO -eq 1 ]]; then
    step "ISO"
    warn "uploading $iso_size — this is the slow part"
    run aws s3 cp "$iso" "s3://$BUCKET/$ISO_KEY" \
        --content-type application/octet-stream \
        --cache-control "public, max-age=86400" \
        --only-show-errors
    ok "s3://$BUCKET/$ISO_KEY"

    # A checksum costs one file and saves the argument about whether a 3GB
    # download arrived intact.
    step "Checksum"
    if [[ $DRY -eq 1 ]]; then
        printf '    %s[dry-run]%s sha256sum %s\n' "$C_Y" "$C_0" "$(basename "$iso")"
    else
        sum="$(sha256sum "$iso" | cut -d' ' -f1)"
        printf '%s  %s\n' "$sum" "$ISO_KEY" > /tmp/starch-iso.sha256
        aws s3 cp /tmp/starch-iso.sha256 "s3://$BUCKET/$ISO_KEY.sha256" \
            --content-type text/plain --cache-control "public, max-age=300" --only-show-errors
        rm -f /tmp/starch-iso.sha256
        ok "sha256 $sum"
    fi
fi

# ── the site ─────────────────────────────────────────────────────────────────
# The repo keeps the placeholder URL so index.html stays a template; the real
# one is substituted into a copy at deploy time. Editing the committed file to
# publish would mean the repo never matches what is live.
step "Site"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
cp -r "$WEB"/. "$stage"/
placeholder="https://REPLACE-ME.s3.amazonaws.com/starch-x86_64.iso"
if grep -q "$placeholder" "$stage/index.html"; then
    sed -i "s|$placeholder|$iso_url|g" "$stage/index.html"
    ok "download links point at $iso_url"
else
    warn "placeholder not found in index.html — links left as they are"
fi

# Assets are content-addressed by nothing, so they get a short cache; the page
# itself must not be cached or a republish is invisible for a day.
run aws s3 sync "$stage/assets/" "s3://$BUCKET/assets/" \
    --cache-control "public, max-age=604800" --only-show-errors --delete
run aws s3 cp "$stage/style.css" "s3://$BUCKET/style.css" \
    --content-type "text/css" --cache-control "public, max-age=3600" --only-show-errors
run aws s3 cp "$stage/index.html" "s3://$BUCKET/index.html" \
    --content-type "text/html; charset=utf-8" --cache-control "no-cache" --only-show-errors
ok "site uploaded"

# ── done ─────────────────────────────────────────────────────────────────────
step "Done"
cat <<EOF

  Site      ${endpoint}
  ISO       ${iso_url}
  Checksum  ${iso_url}.sha256

  Re-run this after editing the page; --no-iso skips the 3GB upload.

EOF
