FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y curl gnupg2 apt-transport-https ca-certificates && \
    curl "https://packages.microsoft.com/keys/microsoft.asc" | tee /etc/apt/trusted.gpg.d/microsoft.asc && \
    curl "https://packages.microsoft.com/config/ubuntu/22.04/prod.list" | tee /etc/apt/sources.list.d/mssql-release.list && \
    apt-get update && \
    ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENV PATH="$PATH:/opt/mssql-tools18/bin"
