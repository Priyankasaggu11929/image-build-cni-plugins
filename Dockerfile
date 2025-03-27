#!UseOBSRepositories

#!BuildTag: rancher/image-build-cni-plugins:v1.6.2
#!BuildTag: rancher/image-build-cni-plugins:latest
#!BuildName: image-build-cni-plugins

ARG BCI_IMAGE=registry.suse.com/bci/bci-busybox
ARG GO_IMAGE=rancher/image-build-base:latest


# ARG GOEXPERIMENT=boringcrypto

### Build the cni-plugins ###
FROM ${GO_IMAGE} AS base_builder
# setup required packages
RUN set -euo pipefail; \
    zypper -n install --no-recommends \
    # file \
    # gcc \
    # git \
    # clang \
    # lld \
    # glibc \
    # glibc-devel-static \    
    musl-gcc \
    musl-libc-static \
    make; \
    zypper -n clean; \
    rm -rf {/target,}/var/log/{alternatives.log,lastlog,tallylog,zypper.log,zypp/history,YaST2}

ARG TARGETPLATFORM

FROM base_builder AS cni_plugins_builder
ARG TAG=v1.6.2
ARG FLANNEL_TAG=v1.6.2-flannel1
ARG BOND_COMMIT=80bef2cd60be32bef9dc08b1a30aaea5282c0311

ENV C_INCLUDE_PATH="/usr/x86_64-linux-musl/include/:/usr/include/"
ENV CC="musl-gcc"

# ARG GOEXPERIMENT
#clone and get dependencies

COPY plugins $GOPATH/src/github.com/containernetworking/plugins

COPY bond-cni $GOPATH/src/github.com/k8snetworkplumbingwg/bond-cni

COPY cni-plugin $GOPATH/src/github.com/flannel-io/cni-plugin
ADD vendor.tar.gz $GOPATH/src/github.com/flannel-io/cni-plugin


ARG TARGETPLATFORM
ENV CGO_ENABLED=1
# cross-compile cni-plugins
RUN cd $GOPATH/src/github.com/containernetworking/plugins && \
     sh -ex ./build_linux.sh -v \
    -gcflags=-trimpath=/go/src \
    -mod=vendor -buildvcs=false \
    -ldflags " \
        -X github.com/containernetworking/plugins/pkg/utils/buildversion.BuildVersion=${TAG} \
        -linkmode=external -extldflags \"-static -Wl,--fatal-warnings\" \
    "

# cross-compile flannel
RUN cd $GOPATH/src/github.com/flannel-io/cni-plugin && \
    make build_linux && \
    mkdir -p $GOPATH/src/github.com/containernetworking/plugins/bin && \
    mv $GOPATH/src/github.com/flannel-io/cni-plugin/dist/flannel-${ARCH} $GOPATH/src/github.com/containernetworking/plugins/bin/flannel
# cross-compile bond
RUN cd $GOPATH/src/github.com/k8snetworkplumbingwg/bond-cni && \
    go build -ldflags "-linkmode=external -extldflags \"-static -Wl,--fatal-warnings\"" -mod=vendor -buildvcs=false -o ./bin/bond ./bond/ && \
    mkdir -p $GOPATH/src/github.com/containernetworking/plugins/bin && \
    mv $GOPATH/src/github.com/k8snetworkplumbingwg/bond-cni/bin/bond $GOPATH/src/github.com/containernetworking/plugins/bin/bond

WORKDIR $GOPATH/src/github.com/containernetworking/plugins
RUN go-assert-static.sh bin/* && \
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
