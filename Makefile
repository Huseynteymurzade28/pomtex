CRYSTAL ?= crystal
SHARDS  ?= shards
PREFIX  ?= $(HOME)/.local
BIN     := bin/pomtex
SOURCES := $(shell find src -name '*.cr')

# Static builds need musl; the official Alpine image ships static libs for
# OpenSSL, zlib, PCRE2 and libgc.
STATIC_IMAGE ?= crystallang/crystal:latest-alpine

.PHONY: all build release static static-native spec fmt lint install uninstall clean

all: build

build: $(BIN)

$(BIN): $(SOURCES) shard.yml
	@mkdir -p bin
	$(CRYSTAL) build src/pomtex.cr -o $(BIN)

release: $(SOURCES)
	@mkdir -p bin
	$(CRYSTAL) build src/pomtex.cr -o $(BIN) --release --no-debug

# Fully static x86_64 binary (via Docker/Podman and Alpine musl).
static:
	@mkdir -p bin
	docker run --rm -v $(CURDIR):/src -w /src $(STATIC_IMAGE) \
	  sh -c 'apk add --no-cache openssl-libs-static zlib-static && \
	         crystal build src/pomtex.cr -o $(BIN) --release --no-debug --static && \
	         strip $(BIN) && chown $(shell id -u):$(shell id -g) $(BIN)'
	@file $(BIN) 2>/dev/null || true

# Static build without Docker; only works on a musl host such as Alpine.
static-native:
	@mkdir -p bin
	$(CRYSTAL) build src/pomtex.cr -o $(BIN) --release --no-debug --static

spec:
	$(CRYSTAL) spec

fmt:
	$(CRYSTAL) tool format src spec

lint:
	$(CRYSTAL) tool format --check src spec

install: release
	install -Dm755 $(BIN) $(PREFIX)/bin/pomtex

uninstall:
	rm -f $(PREFIX)/bin/pomtex

clean:
	rm -rf bin .crystal
