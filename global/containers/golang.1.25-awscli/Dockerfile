FROM golang:1.25

RUN apt-get update && apt-get install --yes --no-install-recommends unzip \
	&& apt-get clean autoclean \
	&& apt-get autoremove --yes \
	&& rm -rf /var/lib/apt/lists/* \
	&& rm -rf /var/lib/{apt,dpkg,cache,log}

ARG AWS_CLI_FOLDER="aws"
ARG AWS_CLI_ZIP_NAME="awscli-exe-linux-x86_64.zip"
RUN cd /tmp && wget "https://awscli.amazonaws.com/$AWS_CLI_ZIP_NAME" \
	&& unzip "$AWS_CLI_ZIP_NAME" && ./$AWS_CLI_FOLDER/install \
	&& rm -rf * && aws --version

ARG AWS_SAM_FOLDER="aws-sam-installation"
ARG AWS_SAM_ZIP_NAME="aws-sam-cli-linux-x86_64.zip"
RUN cd /tmp && wget "https://github.com/aws/aws-sam-cli/releases/latest/download/$AWS_SAM_ZIP_NAME" \
	&& unzip "$AWS_SAM_ZIP_NAME" -d "$AWS_SAM_FOLDER" && ./$AWS_SAM_FOLDER/install \
	&& rm -rf * && sam --version