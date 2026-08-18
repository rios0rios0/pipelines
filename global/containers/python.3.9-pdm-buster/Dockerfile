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

# Pinned and binary-only. An unversioned install bakes whatever PyPI served on
# build day into the image, and an sdist runs its `setup.py` during the build.
#
# Held at 2.26.9 rather than the 2.28.1 the other two images use, and rather
# than the version in global/scripts/shared/pinned-versions.sh: PDM dropped
# Python 3.9 in 2.27, so 2.28.1 declares `requires_python >=3.10` and pip would
# refuse it on this image. 2.26.9 is the last release that still supports 3.9.
RUN pip install --only-binary :all: "pdm==2.26.9"
RUN groupadd --system -g 1001 themaker \
  && useradd --system --create-home -g 1001 --no-user-group -u 1001 themaker
