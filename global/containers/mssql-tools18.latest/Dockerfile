FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

RUN apt-get update && \
    apt-get install -y curl gnupg2 apt-transport-https ca-certificates && \
    curl -fsSL --proto '=https' --proto-redir '=https' "https://packages.microsoft.com/keys/microsoft.asc" | tee /etc/apt/trusted.gpg.d/microsoft.asc && \
    curl -fsSL --proto '=https' --proto-redir '=https' "https://packages.microsoft.com/config/ubuntu/22.04/prod.list" | tee /etc/apt/sources.list.d/mssql-release.list && \
    apt-get update && \
    ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENV PATH="$PATH:/opt/mssql-tools18/bin"

# Runs as a non-root user. This image only invokes `sqlcmd` against a remote
# server -- it declares no VOLUME, writes nothing to the image filesystem at
# run time, and is not used as a CI job container anywhere in this repository,
# so dropping root costs it nothing.
#
# The sibling images deliberately still run as root and are NOT changed here:
# `awscli` and `golang-awscli` are GitLab CI job images, where the runner
# clones into `/builds` and a non-root build container cannot write there
# without runner-side configuration; and `bfg` rewrites a git repository
# mounted at `/code`, so it must be able to write to the caller's bind mount,
# which only works when the container user matches the host's UID.
RUN useradd --create-home --shell /bin/bash mssql
USER mssql
