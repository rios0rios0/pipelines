FROM amazon/aws-cli:latest@sha256:d55d5b391f1cc0d428a05eb07408bb1a730d7df9f656008f1117ed5e13b0c083

RUN yum install -y unzip; yum clean all

ARG TARGETARCH

RUN SAM_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "x86_64") \
	&& cd /tmp && curl -LO --proto '=https' --proto-redir '=https' "https://github.com/aws/aws-sam-cli/releases/latest/download/aws-sam-cli-linux-${SAM_ARCH}.zip" \
	&& unzip "aws-sam-cli-linux-${SAM_ARCH}.zip" -d "aws-sam-installation" && ./aws-sam-installation/install \
	&& rm -rf * && sam --version

ENTRYPOINT ["/bin/bash", "-c"]
