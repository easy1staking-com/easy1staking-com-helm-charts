FROM ubuntu:22.04 AS build

RUN apt update && apt install -y curl

WORKDIR /iagon
RUN curl -LO https://github.com/Iagonorg/mainnet-node-CLI/releases/download/v1.1.0/iag-cli-linux && \
    chmod +x iag-cli-linux

FROM ubuntu:22.04

COPY iag-cli-node-checker.sh /opt
COPY --from=build /iagon/iag-cli-linux /usr/local/bin

CMD [ "bash", "/opt/iag-cli-node-checker.sh" ]
