# TODO: needs to be reviewed to use alpine
FROM python:3.13-slim-bullseye

RUN pip install pdm
RUN groupadd --system -g 1001 app_user \
  && useradd --system --create-home -g 1001 --no-user-group -u 1001 app_user
