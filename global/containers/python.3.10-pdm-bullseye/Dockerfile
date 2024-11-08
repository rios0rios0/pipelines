# TODO: needs to be reviewed to use alpine
FROM python:3.10-slim-bullseye

RUN apt-get update && apt-get install -y --no-install-recommends \
  gcc \
  libglib2.0-dev \
  libharfbuzz-bin \
  libpango-1.0-0 \
  libpangocairo-1.0-0 \
  libpangoft2-1.0-0 \
  libpq-dev \
  python3-dev \
  && apt-get clean autoclean \
  && apt-get autoremove --yes \
  && rm -rf /var/lib/apt/lists/* \
  && rm -rf /var/lib/{apt,dpkg,cache,log}/ # nosemgrep: generic.dockerfile.best-practice.remove-package-lists.remove-package-lists

RUN pip install pdm
RUN groupadd --system -g 1001 themaker \
  && useradd --system --create-home -g 1001 --no-user-group -u 1001 themaker
