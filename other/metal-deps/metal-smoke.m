#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_mtl.h>
#include <stdbool.h>
#include <stdio.h>
#include <unistd.h>

static void fail(const char *step, int error)
{
    fprintf(stderr, "%s: %s (%d)\n", step, mpv_error_string(error), error);
    exit(1);
}

int main(int argc, const char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <video>\n", argv[0]);
        return 2;
    }

    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        NSRect rect = NSMakeRect(0, 0, 320, 180);
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:rect
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO];
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = MTLCreateSystemDefaultDevice();
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        layer.drawableSize = CGSizeMake(320, 180);
        window.contentView.wantsLayer = YES;
        window.contentView.layer = layer;
        [window orderFront:nil];

        mpv_handle *mpv = mpv_create();
        if (!mpv)
            fail("mpv_create", MPV_ERROR_NOMEM);
        mpv_set_option_string(mpv, "vo", "libmpv");
        mpv_set_option_string(mpv, "ao", "null");
        mpv_set_option_string(mpv, "hwdec", "videotoolbox");
        mpv_set_option_string(mpv, "video-sync", "display-desync");
        mpv_set_option_string(mpv, "screenshot-sw", "yes");
        int error = mpv_initialize(mpv);
        if (error < 0)
            fail("mpv_initialize", error);

        mpv_metal_init_params metal = {
            .layer = (__bridge void *)layer,
            .metal_device = (__bridge void *)layer.device,
        };
        const char *api = MPV_RENDER_API_TYPE_METAL;
        mpv_render_param create_params[] = {
            {MPV_RENDER_PARAM_API_TYPE, (void *)api},
            {MPV_RENDER_PARAM_METAL_INIT_PARAMS, &metal},
            {MPV_RENDER_PARAM_INVALID, NULL},
        };
        mpv_render_context *render = NULL;
        error = mpv_render_context_create(&render, mpv, create_params);
        if (error < 0)
            fail("mpv_render_context_create(metal)", error);

        const char *command[] = {"loadfile", argv[1], NULL};
        error = mpv_command(mpv, command);
        if (error < 0)
            fail("loadfile", error);

        bool configured = false;
        int rendered = 0;
        for (int tick = 0; tick < 600 && rendered < 3; tick++) {
            NSEvent *event;
            while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                 untilDate:[NSDate date]
                                                    inMode:NSDefaultRunLoopMode
                                                   dequeue:YES]))
                [NSApp sendEvent:event];

            for (;;) {
                mpv_event *event = mpv_wait_event(mpv, 0);
                if (event->event_id == MPV_EVENT_NONE)
                    break;
                if (event->event_id == MPV_EVENT_VIDEO_RECONFIG)
                    configured = true;
                if (event->event_id == MPV_EVENT_SHUTDOWN)
                    fail("unexpected shutdown", MPV_ERROR_GENERIC);
            }

            if (mpv_render_context_update(render) & MPV_RENDER_UPDATE_FRAME) {
                int flip = 0;
                mpv_render_param frame_params[] = {
                    {MPV_RENDER_PARAM_FLIP_Y, &flip},
                    {MPV_RENDER_PARAM_INVALID, NULL},
                };
                error = mpv_render_context_render(render, frame_params);
                if (error < 0)
                    fail("mpv_render_context_render(metal)", error);
                rendered++;
            }
            usleep(10000);
        }

        int64_t width = 0;
        error = mpv_get_property(mpv, "video-params/w", MPV_FORMAT_INT64, &width);
        if (!configured || rendered == 0 || error < 0 || width <= 0) {
            fprintf(stderr, "smoke incomplete: configured=%d rendered=%d width=%lld error=%d\n",
                    configured, rendered, width, error);
            return 2;
        }

        NSString *screenshotPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"iina-metal-smoke.png"];
        unlink(screenshotPath.fileSystemRepresentation);
        const char *screenshotCommand[] = {
            "screenshot-to-file", screenshotPath.fileSystemRepresentation, "subtitles", NULL
        };
        error = mpv_command_async(mpv, 1, screenshotCommand);
        if (error < 0)
            fail("screenshot-to-file", error);

        bool screenshotDone = false;
        for (int tick = 0; tick < 600 && !screenshotDone; tick++) {
            for (;;) {
                mpv_event *event = mpv_wait_event(mpv, 0);
                if (event->event_id == MPV_EVENT_NONE)
                    break;
                if (event->event_id == MPV_EVENT_COMMAND_REPLY && event->reply_userdata == 1) {
                    if (event->error < 0)
                        fail("screenshot command reply", event->error);
                    screenshotDone = true;
                }
                if (event->event_id == MPV_EVENT_SHUTDOWN)
                    fail("unexpected shutdown", MPV_ERROR_GENERIC);
            }

            if (mpv_render_context_update(render) & MPV_RENDER_UPDATE_FRAME) {
                int flip = 0;
                mpv_render_param frame_params[] = {
                    {MPV_RENDER_PARAM_FLIP_Y, &flip},
                    {MPV_RENDER_PARAM_INVALID, NULL},
                };
                error = mpv_render_context_render(render, frame_params);
                if (error < 0)
                    fail("mpv_render_context_render(screenshot)", error);
            }
            usleep(10000);
        }
        if (!screenshotDone || access(screenshotPath.fileSystemRepresentation, R_OK) != 0) {
            fprintf(stderr, "software screenshot smoke failed: reply=%d path=%s\n",
                    screenshotDone, screenshotPath.fileSystemRepresentation);
            return 2;
        }
        unlink(screenshotPath.fileSystemRepresentation);

        printf("metal smoke ok: configured=%d rendered=%d screenshot=1 width=%lld device=%s\n",
               configured, rendered, width, layer.device.name.UTF8String);
        mpv_render_context_free(render);
        mpv_terminate_destroy(mpv);
        [window orderOut:nil];
    }
    return 0;
}
