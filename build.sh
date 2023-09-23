#!/usr/bin/env bash

make build-and-push NAME=awscli TAG=latest
make build-and-push NAME=bfg TAG=latest
make build-and-push NAME=golang TAG=1.18-awscli
make build-and-push NAME=golang TAG=1.19-awscli
make build-and-push NAME=python TAG=3.9-pdm-buster
make build-and-push NAME=python TAG=3.10-pdm-bullseye
make build-and-push NAME=tor-proxy TAG=latest
