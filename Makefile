.PHONY: demo build test test-daemon clean
PYTHON ?= python3
CC ?= cc

demo:
	$(PYTHON) -m uvp_server.server
build:
	$(MAKE) -C vendor/uvp-live-fio all

test-daemon:
	mkdir -p build
	$(CC) -DUVP_NO_BPF -Ivendor/uvp-live-fio/include -std=gnu11 -O2 -g -Wall -Wextra -Wshadow -Wformat=2 -Werror vendor/uvp-live-fio/src/daemon.c vendor/uvp-live-fio/src/process.c -o build/uvp-daemon-selftest
	$(CC) -Ivendor/uvp-live-fio/include -Wall -Wextra -Werror vendor/uvp-live-fio/tests/test-logic.c -o build/test-logic
	./build/test-logic

test: test-daemon
	$(PYTHON) -m unittest discover -s tests -v
	UVP_DAEMON="$(CURDIR)/build/uvp-daemon-selftest" bash vendor/uvp-live-fio/tests/test-userspace.sh
	bash vendor/uvp-live-fio/tests/test-guest-mock.sh
	UVP_DAEMON="$(CURDIR)/build/uvp-daemon-selftest" bash vendor/uvp-live-fio/tests/test-action-mock.sh
	UVP_DAEMON="$(CURDIR)/build/uvp-daemon-selftest" bash vendor/uvp-live-fio/tests/test-watchdog.sh
clean:
	rm -rf build
