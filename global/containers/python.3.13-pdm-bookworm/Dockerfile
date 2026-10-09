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
FROM python:3.13-slim-bookworm@sha256:a1165e272e578941b84abc79e4ab38a0305cd12803a5c4247979ac7655f4d641

# Pinned and binary-only, matching global/scripts/shared/pinned-versions.sh.
# An unversioned install bakes whatever PyPI served on build day into the
# image, and an sdist runs its `setup.py` during the build.
RUN pip install --only-binary :all: "pdm==2.29.2"
RUN groupadd --system -g 1001 app_user \
  && useradd --system --create-home -g 1001 --no-user-group -u 1001 app_user
