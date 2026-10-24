// Deterministic slow-volume stand-in. Only generated fixture paths are delayed.
#include <sys/stat.h>
#include <sys/attr.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>
static _Atomic int armed, main_calls;
void welcome_io_begin(void) { atomic_store(&main_calls,0); atomic_store(&armed,1); }
int welcome_io_end(void) { atomic_store(&armed,0); return atomic_load(&main_calls); }
static void probe(const char *path) {
  if (atomic_load(&armed) && pthread_main_np() && path && strstr(path,"yina-slow-fixture") && strstr(path,"/media")) {
    atomic_fetch_add(&main_calls,1);
    usleep(100000);
  }
}
static int test_stat(const char *p,struct stat *s) { probe(p); return stat(p,s); }
static int test_lstat(const char *p,struct stat *s) { probe(p); return lstat(p,s); }
static int test_getattrlist(const char *p,struct attrlist *a,void *b,size_t n,unsigned long o) {
  probe(p); return getattrlist(p,a,b,n,o);
}
#define INTERPOSE(a,b) __attribute__((used)) static struct {const void *replacement,*replacee;} pair_##b __attribute__((section("__DATA,__interpose")))={(const void*)&a,(const void*)&b};
INTERPOSE(test_stat,stat)
INTERPOSE(test_lstat,lstat)
INTERPOSE(test_getattrlist,getattrlist)
