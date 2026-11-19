# SPDX-License-Identifier: GPL-2.0-only
CC ?= cc
CLANG ?= clang
PKG_CONFIG ?= pkg-config
PREFIX ?= /usr/local
DESTDIR ?=
MULTIARCH := $(shell $(CC) -dumpmachine)
CFLAGS ?= -O2 -g
CFLAGS += -std=gnu11 -Wall -Wextra -Wshadow -Wformat=2
LIBBPF_CFLAGS := $(shell $(PKG_CONFIG) --cflags libbpf 2>/dev/null)
LIBBPF_LIBS := $(shell $(PKG_CONFIG) --libs libbpf 2>/dev/null)
CPPFLAGS += -Iinclude $(LIBBPF_CFLAGS) -DUVP_INSTALLED_BPF='"$(PREFIX)/lib/uvp-live-fio/hooks.bpf.o"'
BPF_FLAGS := -g -O2 -target bpfel -mcpu=v3 -D__TARGET_ARCH_x86 -Iinclude \
             -I/usr/include/$(MULTIARCH) $(LIBBPF_CFLAGS) -Wall -Wextra
.PHONY: all daemon bpf check-deps check-bpf test install clean
all: daemon bpf
daemon: bin/uvp-daemon
bpf: bin/hooks.bpf.o
bin:
	mkdir -p $@
check-deps:
	@$(PKG_CONFIG) --exists libbpf || { echo 'Install libbpf-dev and pkg-config'; exit 1; }
check-bpf: check-deps
	@test "$$(uname -m)" = x86_64 || { echo 'Native x86-64 only'; exit 1; }
	@$(CLANG) --print-targets | grep -q bpf || { echo 'Use distro clang with BPF backend: make CLANG=/usr/bin/clang'; exit 1; }
bin/uvp-daemon: src/daemon.c src/process.c include/uvp.h include/process.h | bin check-deps
	$(CC) $(CPPFLAGS) $(CFLAGS) src/daemon.c src/process.c -o $@ $(LDFLAGS) $(LIBBPF_LIBS)
bin/hooks.bpf.o: src/hooks.bpf.c include/uvp.h | bin check-bpf
	$(CLANG) $(BPF_FLAGS) -c $< -o $@
bin/test-logic: tests/test-logic.c include/uvp.h | bin
	$(CC) -Iinclude $(CFLAGS) $< -o $@
test: daemon bin/test-logic
	./bin/test-logic
	./tests/test-userspace.sh
	./tests/test-guest-mock.sh
	./tests/test-action-mock.sh
	./tests/test-watchdog.sh
install: all
	install -d $(DESTDIR)$(PREFIX)/sbin $(DESTDIR)$(PREFIX)/lib/uvp-live-fio
	install -m 0755 bin/uvp-daemon $(DESTDIR)$(PREFIX)/sbin/
	install -m 0644 bin/hooks.bpf.o $(DESTDIR)$(PREFIX)/lib/uvp-live-fio/
clean:
	rm -rf bin
