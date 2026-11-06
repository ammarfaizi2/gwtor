# syntax=docker/dockerfile:1
#
# gwproxy, built from the gwproxy submodule with clang 23 and ThinLTO.
#
# Build context: this directory. The sources come from the additional
# build context "gwproxy-src" (the submodule checkout), e.g.:
#
#   docker build --build-context gwproxy-src=gwproxy docker/gwproxy

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
COPY --from=gwproxy-src . /src/gwproxy
WORKDIR /src/gwproxy
# The submodule's .git is a gitfile pointing outside the build context.
RUN set -eux; \
	rm -f .git; \
	make distclean >/dev/null 2>&1 || true; \
	CFLAGS="-O2 -flto=thin" \
	LDFLAGS="-flto=thin -fuse-ld=lld" \
		./configure --cc="${CC}"; \
	make -j"$(nproc)" gwproxy; \
	# Fail the build if the objects are not LLVM bitcode, i.e. LTO
	# did not actually take part in the link.
	file src/gwproxy/gwproxy.c.o | grep -q 'LLVM IR bitcode'; \
	"${STRIP}" gwproxy; \
	./gwproxy --help >/dev/null

FROM debian:${DEBIAN_RELEASE}-slim
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends ca-certificates; \
	rm -rf /var/lib/apt/lists/*; \
	useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin \
		gwproxy
COPY --from=build /src/gwproxy/gwproxy /usr/local/bin/gwproxy
USER gwproxy
EXPOSE 9999
ENTRYPOINT ["/usr/local/bin/gwproxy"]
