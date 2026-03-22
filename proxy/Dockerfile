FROM golang:1.23-alpine AS builder
WORKDIR /src
COPY go.mod proxy.go ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /proxy .

FROM alpine:3.21
RUN apk add --no-cache openssl
COPY --from=builder /proxy /proxy
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 443
VOLUME /certs
ENTRYPOINT ["/entrypoint.sh"]
