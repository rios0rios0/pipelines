# TODO: needs to be reviewed to use alpine
#
# Debian 12 "bookworm", for the reason spelled out in the sibling
# `python.3.10-pdm-bookworm/Dockerfile`: bullseye's LTS ended on 2026-08-31 and
# its suites were removed from deb.debian.org. This image installs no apt
# packages of its own, so it had not failed YET -- it would have failed the next
# time anything in it changed, which is the worst moment to discover it. Moving
# both images together is the point; leaving this one behind would just park the
# same 404 in the future.
#
# The codename is part of the published tag (the folder name IS the tag), so the
# directory moved with the base: `python:3.13-pdm-bullseye` ->
# `python:3.13-pdm-bookworm`.
FROM python:3.13-slim-bookworm@sha256:ed86c82274b3c69b52fb5820f358f0bd7df0b603332063cb5c6e32bd220c3e6e

# Pinned and binary-only, matching global/scripts/shared/pinned-versions.sh.
# An unversioned install bakes whatever PyPI served on build day into the
# image, and an sdist runs its `setup.py` during the build.
RUN pip install --only-binary :all: "pdm==2.29.0"
RUN groupadd --system -g 1001 app_user \
  && useradd --system --create-home -g 1001 --no-user-group -u 1001 app_user
