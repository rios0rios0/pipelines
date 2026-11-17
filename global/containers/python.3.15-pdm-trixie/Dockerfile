# The `python.3.14-pdm-trixie` image on the next Python: Debian 13 "trixie", the PDM
# pinned in global/scripts/shared/pinned-versions.sh, no apt packages, and the
# unprivileged `app_user` (uid/gid 1001) that images built on it switch to.
#
# It is built BESIDE the 3.14 image, not in its place. That one stays what the GitLab CI
# PDM template runs and the Python the Azure DevOps PDM template sets up by default, so
# nothing changes for a project until it chooses 3.15: it names this image, and on Azure
# DevOps it also sets the `PYTHON_VERSION` parameter to '3.15'. A project whose shipped
# image runs Python 3.15 can then test and develop on that Python too. Python 3.15 has
# full support until 2028-10 and security fixes until 2031-10.
#
# The folder name IS the published tag, codename included: `detect-changed-folders.sh`
# splits it into the image name and the tag for the container delivery of
# .github/workflows/default.yaml.
FROM python:3.15-slim-trixie@sha256:65a65fc7b30b06cb6df4930fd4650697cb23f4c2698ab81fc87e4b031bc36928

# Pinned and binary-only, matching global/scripts/shared/pinned-versions.sh.
# An unversioned install bakes whatever PyPI served on build day into the
# image, and an sdist runs its `setup.py` during the build. `--no-cache-dir`
# keeps pip's wheel cache out of the layer (hadolint DL3042).
RUN pip install --no-cache-dir --only-binary :all: "pdm==2.29.7" "unearth==0.19.0" "hishel==2.0.0"
RUN groupadd --system -g 1001 app_user \
  && useradd --system --create-home -g 1001 --no-user-group -u 1001 app_user
