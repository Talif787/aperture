# Multi-stage build. The runtime image contains a static binary and nothing else: no
# shell, no package manager, no toolchain. That is both a smaller image and a smaller
# attack surface, and it means a compromised process has nothing to pivot with.

FROM golang:1.24-alpine AS build

WORKDIR /src

# Dependency layer first so it caches independently of source changes.
COPY go.mod go.sum* ./
RUN go mod download

COPY . .

ARG BUILD_VERSION=dev
RUN CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags "-s -w -X main.buildVersion=${BUILD_VERSION}" \
      -o /out/aperture ./cmd/aperture

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/aperture /aperture

USER nonroot:nonroot
EXPOSE 8080

# Distroless has no shell, so the health check is expressed in the orchestrator rather
# than in the image. Cloud Run and Kubernetes both probe /readyz over HTTP.
ENTRYPOINT ["/aperture"]
