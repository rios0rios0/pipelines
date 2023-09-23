FROM amazon/aws-cli:latest

RUN yum install -y unzip; yum clean all

ARG AWS_SAM_FOLDER="aws-sam-installation"
ARG AWS_SAM_ZIP_NAME="aws-sam-cli-linux-x86_64.zip"
RUN cd /tmp && curl -LO "https://github.com/aws/aws-sam-cli/releases/latest/download/$AWS_SAM_ZIP_NAME" \
	&& unzip "$AWS_SAM_ZIP_NAME" -d "$AWS_SAM_FOLDER" && ./$AWS_SAM_FOLDER/install \
	&& rm -rf * && sam --version

ENTRYPOINT ["/bin/bash", "-c"]
