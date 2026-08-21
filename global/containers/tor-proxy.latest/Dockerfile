# KEPT AT OR ABOVE `health/go.mod`'s `go` directive, which is the thing that broke here.
# This stayed on 1.19 for years while an automated dependency bump walked the module's
# directive up to 1.27, and `go build` refuses a directive newer than itself -- so
# `tor-proxy:latest` stopped being publishable on 2026-07-27 and stayed that way, failing with
# `go: errors parsing go.mod`, which names neither version.
#
# The direction of the fix matters: the DIRECTIVE is the requirement and the toolchain follows
# it, never the other way round. Lowering the directive to suit an old builder would quietly
# give up whatever the module is entitled to use. `.github/tests/test-go-module-toolchain.sh`
# holds the two together from now on, and fails the build if this image ever falls behind again.
FROM golang:1.27.0-alpine3.24@sha256:4c9fe60190a2a3350ddc51de80d0224b8a6698d12bdfc999fee45ea9d6c46dbc AS health_builder

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
