.PHONY: controller demo build test test-daemon clean
CC ?= cc
CFLAGS ?= -O2 -g
NATIVE_CFLAGS = -std=c11 -Wall -Wextra -Wformat=2 -Werror
CONTROLLER_BINS = build/uvp-controller build/uvp-ip build/uvp-worker-io
HOST_BINS = build/uvp-qmp

controller: $(CONTROLLER_BINS)

build/uvp-controller: controller/http.c | build/.dir
	$(CC) $(CPPFLAGS) $(CFLAGS) $(NATIVE_CFLAGS) $< $(LDFLAGS) -o $@
build/uvp-ip: controller/ip-address.c | build/.dir
	$(CC) $(CPPFLAGS) $(CFLAGS) $(NATIVE_CFLAGS) $< $(LDFLAGS) -o $@
build/uvp-worker-io: controller/worker-io.c | build/.dir
	$(CC) $(CPPFLAGS) $(CFLAGS) $(NATIVE_CFLAGS) $< $(LDFLAGS) -o $@
build/uvp-qmp: host/qmp.c | build/.dir
	$(CC) $(CPPFLAGS) $(CFLAGS) $(NATIVE_CFLAGS) $< $(LDFLAGS) -o $@
build/.dir:
	mkdir -p build
	touch $@

demo: controller
	./scripts/start-controller.sh --config "$(CURDIR)/config/demo.json"
build: controller $(HOST_BINS)
	$(MAKE) -C vendor/uvp-live-fio all

test-daemon: | build/.dir
	$(CC) $(CPPFLAGS) $(CFLAGS) -DUVP_NO_BPF -Ivendor/uvp-live-fio/include -std=gnu11 -Wall -Wextra -Wshadow -Wformat=2 -Werror vendor/uvp-live-fio/src/daemon.c vendor/uvp-live-fio/src/process.c -o build/uvp-daemon-selftest
	$(CC) $(CPPFLAGS) $(CFLAGS) -Ivendor/uvp-live-fio/include -Wall -Wextra -Werror vendor/uvp-live-fio/tests/test-logic.c -o build/test-logic
	./build/test-logic

test: controller $(HOST_BINS) test-daemon
	bash tests/native.sh
	bash tests/test-host.sh
	bash tests/forms.sh
	bash tests/http-export.sh
	UVP_DAEMON="$(CURDIR)/build/uvp-daemon-selftest" bash vendor/uvp-live-fio/tests/test-userspace.sh
	bash vendor/uvp-live-fio/tests/test-guest-mock.sh
	UVP_DAEMON="$(CURDIR)/build/uvp-daemon-selftest" bash vendor/uvp-live-fio/tests/test-action-mock.sh
	UVP_DAEMON="$(CURDIR)/build/uvp-daemon-selftest" bash vendor/uvp-live-fio/tests/test-watchdog.sh

clean:
	rm -rf build
	$(MAKE) -C vendor/uvp-live-fio clean
