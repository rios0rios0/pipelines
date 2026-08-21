# The builder has to be able to READ `health/go.mod`, which is the thing that broke here.
# It sat at 1.19 while an automated dependency bump walked the module's `go` directive up to
# 1.27, and `go build` refuses a directive newer than itself -- so `tor-proxy:latest` stopped
# being publishable on 2026-07-27 and stayed that way, failing with `go: errors parsing
# go.mod`, which names neither version. `.github/tests/test-go-module-toolchain.sh` now holds
# the two together.
FROM golang:1.26.7-alpine3.24@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS health_builder

COPY health src/health
RUN cd src/health && go build -o /go/health -ldflags="-w -s"

FROM caddy:2.7.4-builder-alpine@sha256:ec3ac7eee8b4635cb9336eb4cb201684d2cd54f6fe3bcbb61469e1114188f461 AS caddy_builder

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
