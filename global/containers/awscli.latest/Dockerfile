FROM amazon/aws-cli:latest@sha256:733d5be1015825e4038c6016f3fa9954868ddee1f611b73be795a9cc2e706bfd

RUN yum install -y unzip; yum clean all

ARG TARGETARCH

RUN SAM_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "x86_64") \
	&& cd /tmp && curl -LO --proto '=https' --proto-redir '=https' "https://github.com/aws/aws-sam-cli/releases/latest/download/aws-sam-cli-linux-${SAM_ARCH}.zip" \
	&& unzip "aws-sam-cli-linux-${SAM_ARCH}.zip" -d "aws-sam-installation" && ./aws-sam-installation/install \
	&& rm -rf * && sam --version

ENTRYPOINT ["/bin/bash", "-c"]
