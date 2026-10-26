// Tests the installed importer directly, avoiding another provider registered for the same UTI.
// Compile with clang -fobjc-arc -framework Foundation; pass the importer bundle and a synthetic 160x90 MKV.
#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef bool (*ImportMetadata)(void *, CFMutableDictionaryRef, CFStringRef, CFStringRef);
int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc != 3) return 64;
    NSBundle *bundle = [NSBundle bundleWithPath:@(argv[1])];
    void *handle = dlopen(bundle.executablePath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    ImportMetadata import = (ImportMetadata)dlsym(handle, "GetMetadataForFile");
    if (!import) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    bool success = import(NULL, (__bridge CFMutableDictionaryRef)attributes, CFSTR("io.yina.mkv"), (__bridge CFStringRef)@(argv[2]));
    NSLog(@"Metadata result: %@", attributes);
    return success && [attributes[@"kMDItemPixelWidth"] intValue] == 160 && [attributes[@"kMDItemPixelHeight"] intValue] == 90 && [attributes[@"kMDItemDurationSeconds"] doubleValue] > 0 ? 0 : 1;
  }
}
