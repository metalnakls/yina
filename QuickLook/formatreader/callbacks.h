//
//  callbacks.h
//  QLVideo
//

#ifndef callbacks_h
#define callbacks_h

#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <os/log.h>
#include <stdlib.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

void setup_av_log_callback(void);

int MEByteSource_read_packet(void *opaque, uint8_t *buf, int buf_size);
int64_t MEByteSource_seek(void *opaque, int64_t offset, int whence);

#ifdef __cplusplus
}
#endif

#endif // !callbacks_h
