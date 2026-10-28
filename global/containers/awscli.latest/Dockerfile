FROM amazon/aws-cli:latest@sha256:6014c77975a4ae237395924cc821333f20bf87c91964a45dd4ed5f3b13b424f5

RUN yum install -y unzip; yum clean all

ARG TARGETARCH

RUN SAM_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "x86_64") \
	&& cd /tmp && curl -LO --proto '=https' --proto-redir '=https' "https://github.com/aws/aws-sam-cli/releases/latest/download/aws-sam-cli-linux-${SAM_ARCH}.zip" \
	&& unzip "aws-sam-cli-linux-${SAM_ARCH}.zip" -d "aws-sam-installation" && ./aws-sam-installation/install \
	&& rm -rf * && sam --version

ENTRYPOINT ["/bin/bash", "-c"]
