#!/usr/bin/env bash
# Regenerate every artifact derived from contracts/.
#
# Generated code is not committed, and CI regenerates and diffs to prove that no
# hand-edited generated file has survived. A protocol change that only lands on one side
# of the wire is the failure mode this guards against, and on this product that failure
# shows up as silent data corruption rather than as a compile error.
set -euo pipefail

cd "$(dirname "$0")/.."

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33m-- \033[0m %s\n' "$*"; }

PROTO_DIR="contracts/proto"
OPENAPI_SPEC="contracts/openapi/aperture.v1.yaml"
GO_OUT="backend/gen"
SWIFT_OUT="ios/Packages/ApertureCore/Sources/ApertureContracts/Generated"

mkdir -p "${GO_OUT}" "${SWIFT_OUT}"

if [[ -d "${PROTO_DIR}" ]] && compgen -G "${PROTO_DIR}/**/*.proto" >/dev/null 2>&1; then
  if command -v protoc >/dev/null 2>&1; then
    log "Generating Go from Protobuf"
    protoc --proto_path="${PROTO_DIR}" \
           --go_out="${GO_OUT}" --go_opt=paths=source_relative \
           --connect-go_out="${GO_OUT}" --connect-go_opt=paths=source_relative \
           $(find "${PROTO_DIR}" -name '*.proto')

    if command -v protoc-gen-swift >/dev/null 2>&1; then
      log "Generating Swift from Protobuf"
      protoc --proto_path="${PROTO_DIR}" --swift_out="${SWIFT_OUT}" \
             $(find "${PROTO_DIR}" -name '*.proto')
    else
      skip "protoc-gen-swift not installed; Swift contract types not regenerated"
    fi
  else
    skip "protoc not installed; nothing generated from Protobuf"
  fi
else
  skip "no .proto files yet (they arrive in Phase 2)"
fi

if [[ -f "${OPENAPI_SPEC}" ]]; then
  if command -v oapi-codegen >/dev/null 2>&1; then
    log "Generating Go server types from OpenAPI"
    oapi-codegen -package gen -generate types,std-http-server \
                 -o "${GO_OUT}/openapi.gen.go" "${OPENAPI_SPEC}"
  else
    skip "oapi-codegen not installed; OpenAPI types not regenerated"
  fi
else
  skip "no OpenAPI document yet (it arrives in Phase 2)"
fi

log "Generation pass complete"
