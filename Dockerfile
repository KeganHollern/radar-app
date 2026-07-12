# syntax=docker/dockerfile:1.7

ARG GO_VERSION=1.25
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS build

WORKDIR /src

COPY backend/go.* ./
RUN go mod download

COPY backend/ ./

ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/radar-api ./cmd/radar-api

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build --chown=nonroot:nonroot /out/radar-api /radar-api

EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/radar-api"]
