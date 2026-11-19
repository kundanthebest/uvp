/* SPDX-License-Identifier: GPL-2.0-only
 * Test-only build shim. Production uses official libbpf headers and library.
 * These functions deliberately cannot load or attach BPF. */
#ifndef UVP_NO_BPF_TEST_H
#define UVP_NO_BPF_TEST_H
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <linux/bpf.h>
struct bpf_object; struct bpf_program; struct bpf_link; struct ring_buffer;
enum libbpf_print_level { LIBBPF_WARN, LIBBPF_INFO, LIBBPF_DEBUG };
#define UNUSED __attribute__((unused))
static inline int bpf_map_delete_elem(int f UNUSED,const void*k UNUSED){return -1;}
static inline int bpf_map_update_elem(int f UNUSED,const void*k UNUSED,const void*v UNUSED,uint64_t x UNUSED){return -1;}
static inline int bpf_map_lookup_elem(int f UNUSED,const void*k UNUSED,void*v UNUSED){return -1;}
static inline void libbpf_set_print(int(*p)(enum libbpf_print_level,const char*,va_list) UNUSED){}
static inline long libbpf_get_error(const void*p UNUSED){return -1;}
static inline struct bpf_object*bpf_object__open_file(const char*p UNUSED,const void*o UNUSED){return NULL;}
static inline int bpf_object__load(struct bpf_object*p UNUSED){return -1;}
static inline int bpf_object__find_map_fd_by_name(struct bpf_object*p UNUSED,const char*n UNUSED){return -1;}
static inline struct bpf_program*bpf_object__find_program_by_name(struct bpf_object*p UNUSED,const char*n UNUSED){return NULL;}
static inline struct bpf_link*bpf_program__attach_kprobe(struct bpf_program*p UNUSED,bool r UNUSED,const char*t UNUSED){return NULL;}
static inline struct bpf_link*bpf_program__attach_raw_tracepoint(struct bpf_program*p UNUSED,const char*t UNUSED){return NULL;}
static inline struct bpf_link*bpf_program__attach_tracepoint(struct bpf_program*p UNUSED,const char*c UNUSED,const char*t UNUSED){return NULL;}
static inline struct ring_buffer*ring_buffer__new(int f UNUSED,int(*p)(void*,void*,size_t) UNUSED,void*c UNUSED,const void*o UNUSED){return NULL;}
static inline int ring_buffer__poll(struct ring_buffer*p UNUSED,int t UNUSED){return -1;}
static inline void ring_buffer__free(struct ring_buffer*p UNUSED){}
static inline void bpf_link__destroy(struct bpf_link*p UNUSED){}
static inline void bpf_object__close(struct bpf_object*p UNUSED){}
#endif
