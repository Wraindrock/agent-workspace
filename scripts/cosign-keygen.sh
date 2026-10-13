#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Generate the cosign key pair used for *key based* image signing.
#
# agent-workspace signs images keylessly by default (GitHub OIDC, no secret
# required). Use key based signing when your fleet verifies images with a
# pinned public key instead of an OIDC identity:
#
#   scripts/cosign-keygen.sh            -> cosign.key, cosign.pub
#   gh secret set SIGNING_SECRET < cosign.key
#   gh secret set SIGNING_PUBLIC_KEY < cosign.pub
#
# cosign.key is gitignored on purpose. Keep the private key out of the repo
# and back it up somewhere safe: losing it invalidates signed images.
# ---------------------------------------------------------------------------
set -euo pipefail

NAME="${1:-agent-workspace}"

command -v cosign >/dev/null 2>&1 || {
  echo "cosign is not installed: https://docs.sigstore.dev/cosign/system_config/installation/" >&2
  exit 1
}

if [[ -f cosign.key ]]; then
  echo "cosign.key already exists; move it away before generating a new key" >&2
  exit 1
fi

echo "generating signing keys for ${NAME}"
cosign generate-key-pair

echo
echo "next steps:"
echo "  gh secret set SIGNING_SECRET < cosign.key"
echo "  gh secret set SIGNING_PUBLIC_KEY < cosign.pub"
echo "  git add cosign.pub && git commit -m 'chore: add image signing public key'"
