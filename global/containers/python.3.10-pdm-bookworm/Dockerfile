# TODO: needs to be reviewed to use alpine
#
# Debian 12 "bookworm", not 11 "bullseye". Bullseye's LTS ended on 2026-08-31 and
# its suites were REMOVED from deb.debian.org rather than frozen in place, so the
# `apt-get install` below started failing outright on both architectures:
#
#   E: Failed to fetch .../libperl5.32_5.32.1-4+deb11u5_amd64.deb  404  Not Found
#   E: Failed to fetch .../libglib2.0-dev_2.66.8-1+deb11u8_amd64.deb  404  Not Found
#
# The 404 is not a mirror glitch to retry: those files no longer exist anywhere on
# the security pool, and every rebuild of this image would have hit it.
#
# Pointing apt at archive.debian.org -- what `python.3.9-pdm-buster` next door does
# -- was considered and rejected here. It works, but it buys a green build by
# shipping a base that receives no security updates at all, and this image is not
# in buster's position: nothing pins it to Python 3.10 on Debian 11, and bookworm
# carries every package below under the same names. An archived base is a decision
# to stop patching; it is the right one only when the alternative breaks consumers.
#
# The codename is part of the PUBLISHED TAG (the folder name IS the tag -- see the
# matrix in .github/workflows/containers.yaml), so the directory was renamed with
# it: `python:3.10-pdm-bullseye` -> `python:3.10-pdm-bookworm`. The old tag is left
# published and simply stops being rebuilt, so anything still pinning it keeps
# working while nothing new is minted on an unsupported base.
FROM python:3.10-slim-bookworm@sha256:68d914ec641a0b69267ce65184d000a2bc3a9ee2590ab702b82250ab2385735a

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

# Pinned and binary-only, matching global/scripts/shared/pinned-versions.sh.
# An unversioned install bakes whatever PyPI served on build day into the
# image, and an sdist runs its `setup.py` during the build.
RUN pip install --only-binary :all: "pdm==2.29.0"
RUN groupadd --system -g 1001 themaker \
  && useradd --system --create-home -g 1001 --no-user-group -u 1001 themaker
