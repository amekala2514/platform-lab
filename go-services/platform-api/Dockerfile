# Stage 1: Build
FROM golang:1.24 AS build

WORKDIR /src
COPY go.mod ./
# Download dependencies first (layer cache friendly)
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/platform-api .

# Stage 2: Minimal runtime image
FROM gcr.io/distroless/base-debian12

COPY --from=build /out/platform-api /platform-api

EXPOSE 8080

ENTRYPOINT ["/platform-api"]
