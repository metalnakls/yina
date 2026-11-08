// Test-only dyld interposer: count actual CoreVideo cache work in generated media probes.
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#include <stdatomic.h>
#include <stdio.h>
static atomic_uint creates, flushes;
static CVReturn countedCreate(CFAllocatorRef allocator, CFDictionaryRef attributes,
                             id<MTLDevice> device, CFDictionaryRef textureAttributes,
                             CVMetalTextureCacheRef *cache) {
    atomic_fetch_add(&creates, 1);
    return CVMetalTextureCacheCreate(allocator, attributes, device, textureAttributes, cache);
}
static void countedFlush(CVMetalTextureCacheRef cache, CVOptionFlags options) {
    atomic_fetch_add(&flushes, 1);
    CVMetalTextureCacheFlush(cache, options);
}
__attribute__((used, section("__DATA,__interpose")))
static struct { const void *replacement; const void *original; } interposers[] = {
    { (const void *)countedCreate, (const void *)CVMetalTextureCacheCreate },
    { (const void *)countedFlush, (const void *)CVMetalTextureCacheFlush },
};
__attribute__((destructor)) static void report(void) {
    fprintf(stderr, "VT_CACHE_COUNTS creates=%u flushes=%u\n", atomic_load(&creates), atomic_load(&flushes));
}
