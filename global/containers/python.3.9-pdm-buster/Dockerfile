# TODO: needs to be reviewed to use alpine
FROM python:3.9-slim-buster@sha256:320a7a4250aba4249f458872adecf92eea88dc6abd2d76dc5c0f01cac9b53990

# Debian 10 (buster) is end-of-life, and its suites were REMOVED from
# deb.debian.org rather than left to go stale: every one of the three the base
# image ships in /etc/apt/sources.list now answers `404 Not Found`, so the
# `apt-get update` below failed the build outright (exit 100) on both
# architectures. The suites live on archive.debian.org, which still serves
# buster, buster-updates and the buster security suite.
#
# Three details are load-bearing and must not be "simplified" away:
#
#   - The archive is reached over HTTPS. Debian's own examples use `http://`,
#     and apt authenticates packages by signature regardless -- but a
#     cleartext fetch still leaks the exact package set of this image to the
#     path and lets an interception downgrade an install to a mirror's older
#     signed state. apt has carried an https method natively since 1.5, so
#     buster's 1.8 needs no apt-transport-https, and the base image already
#     carries the ca-certificates that pip depends on.
#   - `Check-Valid-Until "false"` is REQUIRED, not cosmetic. An archived
#     Release file keeps the `Valid-Until` stamp it was signed with, which for
#     buster has long passed, and apt rejects the whole suite as expired
#     otherwise -- with a message about the release file, which reads exactly
#     like the 404 this commit fixes.
#   - Signature verification stays ON. The archived Release files are still
#     signed by the buster keys already present in the image's
#     debian-archive-keyring, so nothing here needs `[trusted=yes]` or
#     `--allow-unauthenticated`; reaching for either would drop the last
#     integrity check this image has over an archive it no longer controls.
#
# This image exists for consumers pinned to Python 3.9 (itself end-of-life
# since October 2025), so an archived base is the point rather than a
# regression -- the FROM digest above already froze these packages. Rebasing
# onto a supported Debian would mean renaming the directory, and the directory
# name IS the published tag (`python.3.9-pdm-buster` -> `python:3.9-pdm-buster`,
# see the matrix in .github/workflows/containers.yaml), so it would break every
# consumer pinning that tag.
#
# One instruction rather than four: the package lists and the dpkg database are
# deleted at the end, so anything split into a later layer would either restore
# what was just removed or run against a half-dismantled system.
#
# The pdm pin is held at 2.26.9 rather than the 2.28.1 the other two images use,
# and rather than the version in global/scripts/shared/pinned-versions.sh: PDM
# dropped Python 3.9 in 2.27, so 2.28.1 declares `requires_python >=3.10` and
# pip would refuse it on this image. 2.26.9 is the last release that still
# supports 3.9. It is installed binary-only because an sdist runs its
# `setup.py` during the build, and pinned because an unversioned install bakes
# whatever PyPI served on build day into the image.
# nosemgrep: generic.dockerfile.best-practice.remove-package-lists.remove-package-lists
RUN printf '%s\n' \
      'deb https://archive.debian.org/debian buster main' \
      'deb https://archive.debian.org/debian buster-updates main' \
      'deb https://archive.debian.org/debian-security buster/updates main' \
      > /etc/apt/sources.list \
  && printf '%s\n' 'Acquire::Check-Valid-Until "false";' \
      > /etc/apt/apt.conf.d/10-archived-suite \
  && apt-get update \
  && apt-get install -y --no-install-recommends \
    libglib2.0-dev \
    libharfbuzz-bin \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
    libpangoft2-1.0-0 \
  && apt-get clean autoclean \
  && apt-get autoremove --yes \
  && pip install --only-binary :all: "pdm==2.26.9" \
  && groupadd --system -g 1001 themaker \
  && useradd --system --create-home -g 1001 --no-user-group -u 1001 themaker \
  && rm -rf /var/lib/apt/lists/* \
  && rm -rf /var/lib/{apt,dpkg,cache,log}/
