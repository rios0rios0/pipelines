FROM amazon/aws-cli:latest@sha256:b6aeb95d19d7f5a8cae4eb814cb16739b6b2a4f2f46f427ada6a8c9a20d9881d

RUN yum install -y unzip; yum clean all

ARG TARGETARCH

RUN SAM_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "x86_64") \
	&& cd /tmp && curl -LO --proto '=https' --proto-redir '=https' "https://github.com/aws/aws-sam-cli/releases/latest/download/aws-sam-cli-linux-${SAM_ARCH}.zip" \
	&& unzip "aws-sam-cli-linux-${SAM_ARCH}.zip" -d "aws-sam-installation" && ./aws-sam-installation/install \
	&& rm -rf * && sam --version

ENTRYPOINT ["/bin/bash", "-c"]
