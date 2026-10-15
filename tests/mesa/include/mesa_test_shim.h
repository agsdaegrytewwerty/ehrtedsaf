/* Test doubles for Mesa's utility/provider API. The allocator under test is
 * the byte-for-byte upstream C source plus our production patch. */
#ifndef MESA_TEST_SHIM_H
#define MESA_TEST_SHIM_H
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

typedef pthread_mutex_t mtx_t;
enum { mtx_plain = 0 };
static inline int mtx_init(mtx_t *m, int type) {
   (void)type;
   pthread_mutexattr_t attr;
   assert(!pthread_mutexattr_init(&attr));
   assert(!pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_ERRORCHECK));
   int result = pthread_mutex_init(m, &attr);
   assert(!pthread_mutexattr_destroy(&attr));
   return result;
}
static inline void mtx_lock(mtx_t *m) {
   int result = pthread_mutex_lock(m);
   if (result == EDEADLK) {
      fputs("same-manager mutex re-entry\n", stderr);
      exit(86);
   }
   assert(!result);
}
static inline void mtx_unlock(mtx_t *m) { assert(!pthread_mutex_unlock(m)); }
static inline void mtx_destroy(mtx_t *m) { assert(!pthread_mutex_destroy(m)); }

struct list_head { struct list_head *next, *prev; };
static inline void list_inithead(struct list_head *h) { h->next = h->prev = h; }
static inline void list_add(struct list_head *n, struct list_head *h) {
   n->next = h->next; n->prev = h; h->next->prev = n; h->next = n;
}
static inline void list_addtail(struct list_head *n, struct list_head *h) {
   n->prev = h->prev; n->next = h; h->prev->next = n; h->prev = n;
}
static inline void list_del(struct list_head *n) { n->prev->next = n->next; n->next->prev = n->prev; }
static inline void list_delinit(struct list_head *n) { list_del(n); list_inithead(n); }
#define list_entry(p, t, member) ((t *)((char *)(p) - offsetof(t, member)))

static _Thread_local int fail_calloc_after = -1;
static inline void *test_calloc(size_t n, size_t s) {
   if (fail_calloc_after == 0) { fail_calloc_after = -1; return NULL; }
   if (fail_calloc_after > 0) --fail_calloc_after;
   return calloc(n, s);
}
#define CALLOC(n, s) test_calloc(n, s)
#define CALLOC_STRUCT(t) CALLOC(1, sizeof(struct t))
#define FREE(p) free(p)
typedef uint64_t pb_size;
enum pb_usage_flags { PB_USAGE_CPU_READ = 1, PB_USAGE_CPU_WRITE = 2, PB_USAGE_PERSISTENT = 4 };
enum pipe_error { PIPE_OK = 0, PIPE_ERROR_OUT_OF_MEMORY = -1 };
struct pb_desc { unsigned alignment; enum pb_usage_flags usage; };
struct pipe_reference { atomic_int count; };
struct pipe_fence_handle;
struct pb_validate;
struct pb_buffer;
struct pb_vtbl {
   void (*destroy)(void *, struct pb_buffer *);
   void *(*map)(struct pb_buffer *, enum pb_usage_flags, void *);
   void (*unmap)(struct pb_buffer *);
   enum pipe_error (*validate)(struct pb_buffer *, struct pb_validate *, enum pb_usage_flags);
   void (*fence)(struct pb_buffer *, struct pipe_fence_handle *);
   void (*get_base_buffer)(struct pb_buffer *, struct pb_buffer **, pb_size *);
};
struct pb_buffer {
   struct { struct pipe_reference reference; pb_size size; unsigned alignment_log2, usage; } base;
   const struct pb_vtbl *vtbl;
};
struct pb_manager {
   void (*destroy)(struct pb_manager *);
   struct pb_buffer *(*create_buffer)(struct pb_manager *, pb_size, const struct pb_desc *);
   void (*flush)(struct pb_manager *);
};
static inline void pipe_reference_init(struct pipe_reference *r, int count) { atomic_store(&r->count, count); }
static inline bool pipe_is_referenced(struct pipe_reference *r) { return atomic_load(&r->count) != 0; }
static inline void pb_reference(struct pb_buffer **dst, struct pb_buffer *src) {
   struct pb_buffer *old = *dst;
   if (src) atomic_fetch_add(&src->base.reference.count, 1);
   *dst = src;
   if (old && atomic_fetch_sub(&old->base.reference.count, 1) == 1) old->vtbl->destroy(NULL, old);
}
static inline void *pb_map(struct pb_buffer *b, enum pb_usage_flags f, void *c) { return b->vtbl->map(b, f, c); }
static inline void pb_unmap(struct pb_buffer *b) { b->vtbl->unmap(b); }
static inline enum pipe_error pb_validate(struct pb_buffer *b, struct pb_validate *v, enum pb_usage_flags f) { return b->vtbl->validate(b, v, f); }
static inline void pb_fence(struct pb_buffer *b, struct pipe_fence_handle *f) { b->vtbl->fence(b, f); }
static inline void pb_get_base_buffer(struct pb_buffer *b, struct pb_buffer **o, pb_size *s) { b->vtbl->get_base_buffer(b, o, s); }
static inline bool pb_check_alignment(unsigned requested, unsigned provided) { return provided % requested == 0; }
static inline bool pb_check_usage(unsigned requested, unsigned provided) { return (requested & provided) == requested; }
static inline unsigned util_logbase2(unsigned n) { unsigned r = 0; while (n >>= 1) ++r; return r; }
#endif
