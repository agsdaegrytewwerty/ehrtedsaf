/* Compile the actual Mesa allocator with deterministic provider callbacks. */
#include "mesa_test_shim.h"
#include "pb_bufmgr_slab.c"
#include <string.h>

struct gate {
   pthread_mutex_t mutex;
   pthread_cond_t cond;
   unsigned arrived, target;
};
static void gate_wait(struct gate *g) {
   assert(!pthread_mutex_lock(&g->mutex));
   if (++g->arrived == g->target) assert(!pthread_cond_broadcast(&g->cond));
   while (g->arrived < g->target) assert(!pthread_cond_wait(&g->cond, &g->mutex));
   assert(!pthread_mutex_unlock(&g->mutex));
}
struct provider {
   struct pb_manager base;
   atomic_int live, mapped;
   bool fail_create, fail_map;
   _Atomic(struct pb_buffer *) reclaim_create, reclaim_destroy;
   struct gate *creation_gate;
};
struct backing { struct pb_buffer base; struct provider *provider; void *data; bool mapped; };
static void backing_destroy(void *unused, struct pb_buffer *buf) {
   (void)unused;
   struct backing *b = (struct backing *)buf;
   struct provider *p = b->provider;
   assert(!b->mapped);
   struct pb_buffer *reclaim = atomic_exchange(&p->reclaim_destroy, NULL);
   if (reclaim) pb_reference(&reclaim, NULL);
   atomic_fetch_sub(&p->live, 1);
   free(b->data); free(b);
}
static void *backing_map(struct pb_buffer *buf, enum pb_usage_flags flags, void *ctx) {
   (void)flags; (void)ctx;
   struct backing *b = (struct backing *)buf;
   if (b->provider->fail_map) return NULL;
   assert(!b->mapped); b->mapped = true;
   atomic_fetch_add(&b->provider->mapped, 1);
   return b->data;
}
static void backing_unmap(struct pb_buffer *buf) {
   struct backing *b = (struct backing *)buf;
   assert(b->mapped); b->mapped = false;
   atomic_fetch_sub(&b->provider->mapped, 1);
}
static const struct pb_vtbl backing_vtbl = { .destroy = backing_destroy, .map = backing_map, .unmap = backing_unmap };
static struct pb_buffer *provider_create(struct pb_manager *mgr, pb_size size, const struct pb_desc *desc) {
   (void)desc;
   struct provider *p = (struct provider *)mgr;
   /* Model d3d12_screen_reclaim_completed during backing allocation. */
   struct pb_buffer *reclaim = atomic_exchange(&p->reclaim_create, NULL);
   if (reclaim) pb_reference(&reclaim, NULL);
   if (p->creation_gate) gate_wait(p->creation_gate);
   if (p->fail_create) return NULL;
   struct backing *b = calloc(1, sizeof(*b)); assert(b);
   b->data = calloc(1, size); assert(b->data);
   b->provider = p; b->base.vtbl = &backing_vtbl;
   b->base.base.size = size;
   pipe_reference_init(&b->base.base.reference, 1);
   atomic_fetch_add(&p->live, 1);
   return &b->base;
}
static const struct pb_desc desc = { .alignment = 16, .usage = PB_USAGE_CPU_READ | PB_USAGE_CPU_WRITE };
static struct pb_manager *manager(struct provider *p, unsigned slab_size) {
   p->base.create_buffer = provider_create;
   return pb_slab_manager_create(&p->base, 32, slab_size, &desc);
}
static struct pb_buffer *allocate(struct pb_manager *m) { return m->create_buffer(m, 32, &desc); }
static void finish(struct provider *p, struct pb_manager *m) {
   assert(atomic_load(&p->live) == 0);
   assert(atomic_load(&p->mapped) == 0);
   assert(pb_slab_manager(m)->slabs.next == &pb_slab_manager(m)->slabs);
   m->destroy(m);
}
static void reclaim_create(bool fail) {
   struct provider p = {0}; struct pb_manager *m = manager(&p, 64);
   struct pb_buffer *a = allocate(m), *b = allocate(m); assert(a && b);
   p.reclaim_create = a; p.fail_create = fail;
   struct pb_buffer *c = allocate(m); assert(c);
   memset(pb_map(b, PB_USAGE_CPU_WRITE, NULL), 0x5a, 32); pb_unmap(b);
   memset(pb_map(c, PB_USAGE_CPU_WRITE, NULL), 0xa5, 32); pb_unmap(c);
   assert(*(unsigned char *)pb_map(b, PB_USAGE_CPU_READ, NULL) == 0x5a); pb_unmap(b);
   assert(atomic_load(&p.live) == (fail ? 1 : 2));
   pb_reference(&b, NULL); pb_reference(&c, NULL); finish(&p, m);
}
static void reclaim_destroy(void) {
   struct provider p = {0}; struct pb_manager *m = manager(&p, 32);
   struct pb_buffer *a = allocate(m), *b = allocate(m); assert(a && b);
   p.reclaim_destroy = b;
   pb_reference(&a, NULL); finish(&p, m);
}
static void reclaim_empty(void) {
   struct provider p = {0}; struct pb_manager *m = manager(&p, 32);
   struct pb_buffer *a = allocate(m); assert(a);
   p.reclaim_create = a;
   struct pb_buffer *b = allocate(m); assert(b);
   assert(atomic_load(&p.live) == 1);
   pb_reference(&b, NULL); finish(&p, m);
}
static void allocation_failures(void) {
   struct provider p = {0}; struct pb_manager *m = manager(&p, 64);
   p.fail_create = true; assert(!allocate(m)); p.fail_create = false;
   p.fail_map = true; assert(!allocate(m)); p.fail_map = false;
   fail_calloc_after = 0; assert(!allocate(m)); /* slab structure */
   fail_calloc_after = 1; assert(!allocate(m)); /* mapped slab's buffer array */
   struct pb_buffer *a = allocate(m); assert(a); pb_reference(&a, NULL);
   finish(&p, m);
}
struct thread_args { struct pb_manager *manager; struct gate *release_gate; };
static void *concurrent_allocate(void *arg) {
   struct thread_args *a = arg;
   struct pb_buffer *b = allocate(a->manager); assert(b);
   gate_wait(a->release_gate);
   pb_reference(&b, NULL);
   return NULL;
}
static void concurrency(void) {
   for (unsigned round = 0; round < 100; ++round) {
      struct gate create = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0, 8 };
      struct gate release = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0, 8 };
      struct provider p = {0}; struct pb_manager *m = manager(&p, 64);
      p.creation_gate = &create;
      struct thread_args arg = { m, &release }; pthread_t threads[8];
      for (unsigned i = 0; i < 8; ++i) assert(!pthread_create(&threads[i], NULL, concurrent_allocate, &arg));
      for (unsigned i = 0; i < 8; ++i) assert(!pthread_join(threads[i], NULL));
      finish(&p, m);
      assert(!pthread_cond_destroy(&create.cond)); assert(!pthread_mutex_destroy(&create.mutex));
      assert(!pthread_cond_destroy(&release.cond)); assert(!pthread_mutex_destroy(&release.mutex));
   }
}
int main(int argc, char **argv) {
   assert(argc == 2);
   if (!strcmp(argv[1], "reclaim-create")) reclaim_create(false);
   else if (!strcmp(argv[1], "reclaim-oom")) reclaim_create(true);
   else if (!strcmp(argv[1], "reclaim-destroy")) reclaim_destroy();
   else if (!strcmp(argv[1], "reclaim-empty")) reclaim_empty();
   else if (!strcmp(argv[1], "oom")) allocation_failures();
   else if (!strcmp(argv[1], "concurrent")) concurrency();
   else abort();
   puts("PASS");
   return 0;
}
