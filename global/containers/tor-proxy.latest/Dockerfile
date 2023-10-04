FROM golang:1.19.0-alpine3.16 AS health_builder

COPY health src/health
RUN cd src/health && go build -o /go/health -ldflags="-w -s"

FROM caddy:2.7.4-builder-alpine AS caddy_builder

RUN xcaddy build \
	--with github.com/mholt/caddy-l4

FROM alpine:edge@sha256:880fafbab5a7602db21ac37f0d17088a29a9a48f98d581f01ce17312c22ccbb5

ENV TOR_HOME /home/tor
RUN apk add --no-cache tor supervisor
RUN mkdir -p "$TOR_HOME" && chown -R tor "$TOR_HOME"

COPY --from=health_builder /go/health /usr/bin/health
COPY --from=caddy_builder /usr/bin/caddy /usr/bin/caddy

COPY config/torrc .
COPY config/caddy.json .
COPY config/supervisord.conf .

ENTRYPOINT ["/usr/bin/supervisord", "--configuration", "supervisord.conf"]
