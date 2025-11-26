FROM golang:1.25

RUN apt-get update && apt-get install --yes --no-install-recommends unzip \
	&& apt-get clean autoclean \
	&& apt-get autoremove --yes \
	&& rm -rf /var/lib/apt/lists/* \
	&& rm -rf /var/lib/{apt,dpkg,cache,log}

ARG TARGETARCH

RUN AWS_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") \
	&& cd /tmp && wget "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" \
	&& unzip "awscli-exe-linux-${AWS_ARCH}.zip" && ./aws/install \
	&& rm -rf * && aws --version

RUN SAM_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "x86_64") \
	&& cd /tmp && wget "https://github.com/aws/aws-sam-cli/releases/latest/download/aws-sam-cli-linux-${SAM_ARCH}.zip" \
	&& unzip "aws-sam-cli-linux-${SAM_ARCH}.zip" -d "aws-sam-installation" && ./aws-sam-installation/install \
	&& rm -rf * && sam --version
