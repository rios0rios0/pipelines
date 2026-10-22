# TODO: needs to be reviewed to use alpine
#
# The one Python image this repository builds. It replaced `python.3.10-pdm-bookworm`
# and `python.3.13-pdm-bookworm`. Python 3.10 reached end of life on 2026-10-01, and
# 3.13 left full support the same day. Python 3.14 has full support until 2027-10 and
# security fixes until 2030-10, and the Azure DevOps PDM template already runs it.
#
# The base is Debian 13 "trixie", because bookworm's regular security support ended
# on 2026-07-11. The codename is part of the PUBLISHED TAG (the folder name IS the
# tag -- see the matrix in .github/workflows/containers.yaml). The two old tags stay
# published but are no longer rebuilt, so anything still pinning one keeps working
# while nothing new is built on a base that is out of support.
#
# It installs no apt packages; neither did the 3.13 image. The 3.10 image carried a C
# compiler, development headers and the Pango libraries. On trixie those brought in
# most of the image's known vulnerabilities, and no consumer could be found that
# needs them. A project that compiles a C extension with no wheel, or renders with
# Pango, extends this image with what it needs. The unprivileged user is the 3.13
# image's `app_user`, which images built on this one switch to.
FROM python:3.14-slim-trixie@sha256:0b566a9f30a60730df33c26ac62dedb55393d8814645cd03543b67bf8987f3a1

# Pinned and binary-only, matching global/scripts/shared/pinned-versions.sh.
# An unversioned install bakes whatever PyPI served on build day into the
# image, and an sdist runs its `setup.py` during the build.
RUN pip install --only-binary :all: "pdm==2.29.2"
RUN groupadd --system -g 1001 app_user \
  && useradd --system --create-home -g 1001 --no-user-group -u 1001 app_user
