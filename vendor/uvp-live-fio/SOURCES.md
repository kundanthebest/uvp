# Implementation references checked 2026-10-16

Primary references; the exact patched build remains authoritative for its symbols.

* QEMU migration framework: non-iterative device state is saved while guest CPUs
  are paused; explains why SSH-to-start-fio cannot complete at that paused phase.
  https://www.qemu.org/docs/master/devel/migration/main.html
* QEMU VFIO migration: VFIO_DEVICE_FEATURE and migration data-FD paths.
  https://raw.githubusercontent.com/qemu/qemu/master/hw/vfio/migration.c
* libnvme Migration Send/Receive command construction and field definitions:
  https://raw.githubusercontent.com/linux-nvme/libnvme/master/src/nvme/ioctl.c
  https://raw.githubusercontent.com/linux-nvme/libnvme/master/src/nvme/types.h
* NVMe request layout and completion tracepoint:
  https://raw.githubusercontent.com/torvalds/linux/v6.16/drivers/nvme/host/nvme.h
  https://raw.githubusercontent.com/torvalds/linux/v6.16/drivers/nvme/host/trace.h
* BPF ring-buffer reservation and notification semantics:
  https://docs.kernel.org/bpf/ringbuf.html
* pidfd signaling:
  https://man7.org/linux/man-pages/man2/pidfd_send_signal.2.html
* libbpf C APIs:
  https://raw.githubusercontent.com/libbpf/libbpf/v1.5.0/src/libbpf.h
* fio runtime, output and I/O logging options:
  https://fio.readthedocs.io/en/latest/fio_doc.html

Private source context used only for default symbol names:
The supplied `Chaitanya_patches .txt` VFIO-NVMe RFC defines the four int-returning
nvmevf_cmd_* wrappers. This is a historical patch reference, not verification of
your currently running kernel. No copy of that private patch is included here.

Code provenance: this project extends the structure of the previously supplied
uvp-nvme-suspend-gate experiment, with a new VFIO phase adapter, attach-mode
daemon and guest fio scripts. The delivered code is GPL-2.0-only.
