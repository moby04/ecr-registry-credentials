ARG BASE_VERSION

FROM amazon/aws-cli:${BASE_VERSION}

ARG KUBECTL_VERSION=1.19.4

RUN curl -o kubectl https://storage.googleapis.com/kubernetes-release/release/v$KUBECTL_VERSION/bin/linux/amd64/kubectl \
    && chmod +x kubectl \
    && mv kubectl /usr/local/bin

WORKDIR /tmp

COPY set_ecr_credentials.sh /set_ecr_credentials.sh

ENTRYPOINT ["/set_ecr_credentials.sh"]
