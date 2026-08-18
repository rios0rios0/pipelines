FROM eclipse-temurin:8-jre@sha256:8dd4e719809e7acdd9d9007e27a1df3e1dee76def2e55f2c54d8059c19f250f8

# Note: https://rtyley.github.io/bfg-repo-cleaner/
ENV BFG_VERSION 1.14.0
ENV WORK_DIR /code

VOLUME ["${WORK_DIR}"]

RUN wget --quiet --output-document=/bfg.jar https://repo1.maven.org/maven2/com/madgag/bfg/${BFG_VERSION}/bfg-${BFG_VERSION}.jar

RUN echo "#!/usr/bin/env sh" > /usr/bin/bfg \
    && echo "set -e" >> /usr/bin/bfg \
    && echo "if [ \"\$1\" = \"bash\" ]; then" >> /usr/bin/bfg \
    && echo "exec \$@" >> /usr/bin/bfg \
    && echo "fi" >> /usr/bin/bfg \
    && echo "java -jar /bfg.jar \$@" >> /usr/bin/bfg \
    && chmod +x /usr/bin/bfg

WORKDIR ${WORK_DIR}

ENTRYPOINT ["/usr/bin/bfg"]
