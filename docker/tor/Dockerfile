# syntax=docker/dockerfile:1
#
# Tor, built from the tor submodule with clang 23 and ThinLTO, plus the
# tools to bring up a WireGuard tunnel that carries all of its traffic.
#
# Build context: this directory. The sources come from the additional
# build context "tor-src" (the submodule checkout), e.g.:
#
#   docker build --build-context tor-src=tor docker/tor

ARG DEBIAN_RELEASE=trixie
ARG LLVM_VERSION=23

FROM debian:${DEBIAN_RELEASE}-slim AS toolchain
ARG DEBIAN_RELEASE
ARG LLVM_VERSION
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
	curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key \
		| gpg --dearmor -o /usr/share/keyrings/apt.llvm.org.gpg; \
	echo "deb [signed-by=/usr/share/keyrings/apt.llvm.org.gpg]" \
		"https://apt.llvm.org/${DEBIAN_RELEASE}/" \
		"llvm-toolchain-${DEBIAN_RELEASE}-${LLVM_VERSION} main" \
		> /etc/apt/sources.list.d/llvm.list; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		clang-${LLVM_VERSION} lld-${LLVM_VERSION} \
		llvm-${LLVM_VERSION} libc6-dev make file; \
	rm -rf /var/lib/apt/lists/*
ENV CC=clang-${LLVM_VERSION} \
    AR=llvm-ar-${LLVM_VERSION} \
    NM=llvm-nm-${LLVM_VERSION} \
    RANLIB=llvm-ranlib-${LLVM_VERSION} \
    STRIP=llvm-strip-${LLVM_VERSION}

FROM toolchain AS build
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		autoconf automake pkg-config python3 \
		libevent-dev libssl-dev zlib1g-dev libzstd-dev liblzma-dev \
		libcap-dev libseccomp-dev; \
	rm -rf /var/lib/apt/lists/*
COPY --from=tor-src . /src/tor
WORKDIR /src/tor
# The submodule's .git is a gitfile pointing outside the build context.
RUN set -eux; \
	rm -f .git; \
	./autogen.sh; \
	./configure \
		CFLAGS="-O2 -flto=thin" \
		LDFLAGS="-flto=thin -fuse-ld=lld" \
		--prefix=/usr/local \
		--sysconfdir=/etc \
		--localstatedir=/var \
		--disable-module-relay \
		--disable-unittests \
		--disable-asciidoc \
		--disable-manpage \
		--disable-html-manual \
		--enable-zstd \
		--enable-lzma; \
	make -j"$(nproc)"; \
	# Fail the build if the objects are not LLVM bitcode, i.e. LTO
	# did not actually take part in the link.
	file src/app/main/tor_main.o | grep -q 'LLVM IR bitcode'; \
	"${STRIP}" src/app/tor; \
	./src/app/tor --version | grep -q '^Tor version 0\.4\.9\.16\b'

FROM debian:${DEBIAN_RELEASE}-slim
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		ca-certificates curl iproute2 wireguard-tools \
		libevent-2.1-7t64 libssl3t64 zlib1g libzstd1 liblzma5 \
		libcap2 libseccomp2; \
	rm -rf /var/lib/apt/lists/*; \
	useradd --system --home-dir /var/lib/tor --shell /usr/sbin/nologin tor; \
	install -d -o tor -g tor -m 0700 /var/lib/tor
COPY --from=build /src/tor/src/app/tor /usr/local/bin/tor
COPY --from=build /src/tor/src/config/geoip /src/tor/src/config/geoip6 \
	/usr/local/share/tor/
COPY entrypoint.sh /usr/local/sbin/gwtor-entrypoint
VOLUME /var/lib/tor
EXPOSE 8001-8015
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=40 \
	CMD grep -q 'Bootstrapped 100%' /var/lib/tor/notices.log
ENTRYPOINT ["/usr/local/sbin/gwtor-entrypoint"]
