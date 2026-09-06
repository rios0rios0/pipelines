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

# The SAME failure as the stage above, one layer out: a toolchain older than the
# module it is asked to compile. `--with github.com/mholt/caddy-l4` carried no
# version, so xcaddy resolved the plugin's newest release on build day, and on
# 2026-07-16 that became v0.1.2, whose `go.mod` declares `go 1.25.1`. The 2.7.4
# builder ships Go 1.21.3 with `GOTOOLCHAIN=local` -- it cannot fetch another --
# so this stage has failed every run that got past the one above, most recently
# https://github.com/rios0rios0/pipelines/actions/runs/34004977060:
#
#   go: github.com/mholt/caddy-l4@v0.1.2 requires go >= 1.25.1
#       (running go 1.21.3; GOTOOLCHAIN=local)
#
# Both halves of that are now pinned, and BOTH pins are load-bearing:
#
#   - `caddy:2.11.4-builder-alpine` is the current builder (Go 1.26.8, xcaddy
#     0.4.5, `CADDY_VERSION=v2.11.4`). 1.26.8 satisfies the plugin's 1.25.1, and
#     `CADDY_VERSION` is what xcaddy pins Caddy itself to -- caddy-l4 v0.1.2
#     requires `github.com/caddyserver/caddy/v2 v2.11.4` exactly, so builder and
#     plugin agree on the same Caddy rather than one silently downgrading the
#     other. Moving one of these two without checking the other reopens this bug.
#   - `@v0.1.2` on the plugin. An unversioned `--with` is a floating dependency
#     resolved at build time: it is how a 2023 builder ended up being handed a
#     2026 module, and it means the image cannot be rebuilt to match what was
#     published. v0.1.2 (2026-07-16) is the plugin's newest tagged release; it is
#     tagged, so no pseudo-version is needed.
#
# `config/caddy.json` was checked against this ref rather than assumed: the app
# is still `layer4`, and `layer4.matchers.socks5`, `layer4.matchers.http` and
# `layer4.handlers.proxy` (with `upstreams[].dial`) all keep their module IDs and
# JSON shapes, so the config needed no change.
FROM caddy:2.11.4-builder-alpine@sha256:1a1689db91cfb390b2d856a1b3774e796852822cd723fa54c475b272f82bb4b7 AS caddy_builder

RUN xcaddy build \
	--with github.com/mholt/caddy-l4@v0.1.2

FROM alpine:edge@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000

ENV TOR_HOME /home/tor
RUN apk add --no-cache tor supervisor
RUN mkdir -p "$TOR_HOME" && chown -R tor "$TOR_HOME"

COPY --from=health_builder /go/health /usr/bin/health
COPY --from=caddy_builder /usr/bin/caddy /usr/bin/caddy

COPY config/torrc .
COPY config/caddy.json .
COPY config/supervisord.conf .

ENTRYPOINT ["/usr/bin/supervisord", "--configuration", "supervisord.conf"]
