# Relayer image. Cross-compiles on the build host (no QEMU) and ships a
# static binary on distroless.
#
#   docker build -t gno-drand-relayer .
#   docker run --rm -e RELAYER_MNEMONIC="..." gno-drand-relayer -remote https://rpc.gno.land:443

FROM --platform=$BUILDPLATFORM golang:1.26.8-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/relayer ./cmd/relayer

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/relayer /relayer
USER nonroot:nonroot
ENTRYPOINT ["/relayer"]
