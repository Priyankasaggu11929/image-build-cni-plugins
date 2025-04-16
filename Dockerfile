#!UseOBSRepositories

#!BuildTag: rancher/hardened-cni-plugins:v1.6.2
#!BuildTag: rancher/hardened-cni-plugins:latest
#!BuildName: hardened-cni-plugins

# INFO: image-build-base:latest provides the following:
# - required packages (make, musl-gcc, musl-libc-static, etc)
# - set CC, and C_INCLUDE_PATH evironment variables, to enable building with musl libc

ARG BCI_IMAGE=registry.suse.com/bci/bci-busybox
ARG GO_IMAGE=rancher/image-build-base:latest

# ARG GOEXPERIMENT=boringcrypto

### Build the cni-plugins ###
# FROM ${GO_IMAGE} AS base_builder
# FROM base_builder AS cni_plugins_builder

FROM ${GO_IMAGE} AS cni_plugins_builder
ARG TAG=v1.6.2
ARG FLANNEL_TAG=v1.6.2-flannel1
ARG BOND_COMMIT=80bef2cd60be32bef9dc08b1a30aaea5282c0311


# ARG GOEXPERIMENT

#clone and get dependencies

COPY plugins $GOPATH/src/github.com/containernetworking/plugins

COPY bond-cni $GOPATH/src/github.com/k8snetworkplumbingwg/bond-cni

COPY cni-plugin $GOPATH/src/github.com/flannel-io/cni-plugin
ADD vendor.tar.gz $GOPATH/src/github.com/flannel-io/cni-plugin


ARG TARGETPLATFORM
ENV CGO_ENABLED=1
# cross-compile cni-plugins
RUN cd $GOPATH/src/github.com/containernetworking/plugins; \
     sed -i 's|\${GO:-go} build |\${GO:-go} build -mod=vendor -buildvcs=false |' build_linux.sh && \
     sh -ex ./build_linux.sh -v \
    -gcflags=-trimpath=/go/src \
    -ldflags " \
        -X github.com/containernetworking/plugins/pkg/utils/buildversion.BuildVersion=${TAG} \
        -linkmode=external -extldflags \"-static -Wl,--fatal-warnings\" \
    "

# cross-compile flannel
ADD vendor.tar.gz $GOPATH/src/github.com/flannel-io/cni-plugin
RUN if [ "$(uname -m)" == "x86_64" ]; then export ARCH="amd64"; elif [ "$(uname -m)" == "aarch64" ]; then export ARCH="arm64"; fi; \
    cd $GOPATH/src/github.com/flannel-io/cni-plugin; \
    sed -i 's/^build_linux: vendor$/build_linux:/g' Makefile; \
    sed -i 's/go build/go build -mod=vendor -buildvcs=false/g' scripts/build_flannel.sh && \
    make build_linux && \
    mkdir -p $GOPATH/src/github.com/containernetworking/plugins/bin && \
    mv $GOPATH/src/github.com/flannel-io/cni-plugin/dist/flannel-${ARCH} $GOPATH/src/github.com/containernetworking/plugins/bin/flannel
# cross-compile bond
RUN cd $GOPATH/src/github.com/k8snetworkplumbingwg/bond-cni && \
    go build -ldflags "-linkmode=external -extldflags \"-static -Wl,--fatal-warnings\"" -mod=vendor -buildvcs=false -o ./bin/bond ./bond/ && \
    mkdir -p $GOPATH/src/github.com/containernetworking/plugins/bin && \
    mv $GOPATH/src/github.com/k8snetworkplumbingwg/bond-cni/bin/bond $GOPATH/src/github.com/containernetworking/plugins/bin/bond

WORKDIR $GOPATH/src/github.com/containernetworking/plugins
RUN if [ "$(uname -m)" == "x86_64" ]; then export ARCH="amd64"; elif [ "$(uname -m)" == "aarch64" ]; then export ARCH="arm64"; fi; \
    go-assert-static.sh bin/* && \
    if [ "${ARCH}" = "amd64" ]; then \
        go-assert-boring.sh bin/bandwidth \
        bin/bond \
        bin/bridge \
        bin/dhcp \
        bin/firewall \
        bin/host-device \
        bin/host-local \
        bin/ipvlan \
        bin/macvlan \
        bin/portmap \
        bin/ptp \
        bin/vlan ; \
    fi && \
    mkdir -vp /opt/cni/bin && \
    install -D bin/* /opt/cni/bin

FROM ${GO_IMAGE} AS strip_binary
#strip needs to run on TARGETPLATFORM, not BUILDPLATFORM
COPY --from=cni_plugins_builder /opt/cni/ /opt/cni/
RUN for plugin in $(ls /opt/cni/bin); do \
        strip /opt/cni/bin/${plugin}; \
    done


# Create image with the cni-plugins
FROM ${BCI_IMAGE}
COPY --from=strip_binary /opt/cni/ /opt/cni/
WORKDIR /
COPY install-cnis.sh .
ENTRYPOINT ["./install-cnis.sh"]
