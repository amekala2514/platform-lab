FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -ldflags="-s -w" -o /out/platform-api .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/platform-api /platform-api
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/platform-api"]
