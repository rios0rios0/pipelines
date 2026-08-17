# TODO: needs to be reviewed to use alpine
FROM python:3.9-slim-buster@sha256:320a7a4250aba4249f458872adecf92eea88dc6abd2d76dc5c0f01cac9b53990

RUN apt-get update && apt-get install -y --no-install-recommends \
  libglib2.0-dev \
  libharfbuzz-bin \
  libpango-1.0-0 \
  libpangocairo-1.0-0 \
  libpangoft2-1.0-0 \
  && apt-get clean autoclean \
  && apt-get autoremove --yes \
  && rm -rf /var/lib/apt/lists/* \
  && rm -rf /var/lib/{apt,dpkg,cache,log}/ # nosemgrep: generic.dockerfile.best-practice.remove-package-lists.remove-package-lists

RUN pip install pdm
RUN groupadd --system -g 1001 themaker \
  && useradd --system --create-home -g 1001 --no-user-group -u 1001 themaker
