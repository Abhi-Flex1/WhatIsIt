# Build stage
FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/whatisit-server ./cmd/server

# Runtime stage (distroless — pure Go, no CGO)
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/whatisit-server /usr/local/bin/whatisit-server
EXPOSE 18770
ENTRYPOINT ["/usr/local/bin/whatisit-server"]
