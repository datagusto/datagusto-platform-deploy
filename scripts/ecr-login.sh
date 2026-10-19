#!/usr/bin/env bash
# Log Docker in to the Amazon ECR registry you received from datagusto, using
# the access role you were given.
#   ECR_REGISTRY=<registry host> scripts/ecr-login.sh [aws-profile]
# The login is valid for 12 hours; run it again before `docker compose pull`.
set -euo pipefail
PROFILE="${1:-${AWS_PROFILE:-}}"
REGISTRY="${ECR_REGISTRY:-}"
if [ -z "$REGISTRY" ]; then
  # Fall back to IMAGE_REGISTRY from .env in the current directory.
  REGISTRY="$(sed -n 's/^IMAGE_REGISTRY=//p' .env 2>/dev/null | tr -d '/')"
fi
[ -n "$REGISTRY" ] || { echo "set ECR_REGISTRY, or IMAGE_REGISTRY in .env" >&2; exit 1; }
REGION="${REGISTRY#*.dkr.ecr.}"; REGION="${REGION%%.*}"
aws ${PROFILE:+--profile "$PROFILE"} ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"
