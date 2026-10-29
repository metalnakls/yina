#include <mpv/client.h>
#include <mpv/render.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void option(mpv_handle *mpv, const char *key, const char *value) {
  int result = mpv_set_option_string(mpv, key, value);
  if (result < 0) { fprintf(stderr, "%s: %s\n", key, mpv_error_string(result)); exit(2); }
}

static int render_rows(mpv_render_context *render, int width, int height) {
  size_t stride = width * 4;
  unsigned char *pixels = NULL;
  if (posix_memalign((void **)&pixels, 64, stride * height)) exit(2);
  int size[2] = {width, height};
  char format[] = "rgb0";
  mpv_render_param params[] = {
    {MPV_RENDER_PARAM_SW_SIZE, size}, {MPV_RENDER_PARAM_SW_FORMAT, format},
    {MPV_RENDER_PARAM_SW_STRIDE, &stride}, {MPV_RENDER_PARAM_SW_POINTER, pixels},
    {MPV_RENDER_PARAM_INVALID, NULL}
  };
  int status = mpv_render_context_render(render, params);
  if (status < 0) { fprintf(stderr, "render: %s\n", mpv_error_string(status)); exit(2); }
  int rows = 0;
  for (int y = 0; y < height; ++y) {
    int bright = 0;
    for (int x = width / 3; x < width * 2 / 3; ++x) {
      unsigned char *pixel = pixels + y * stride + x * 4;
      if (pixel[0] > 150 && pixel[1] > 150 && pixel[2] > 150) ++bright;
    }
    if (bright >= 5) ++rows;
  }
  free(pixels);
  return rows;
}

int main(int argc, char **argv) {
  if (argc != 5) return 2;
  mpv_handle *mpv = mpv_create();
  if (!mpv) return 2;
  option(mpv, "config", "no"); option(mpv, "load-scripts", "no");
  option(mpv, "vo", "libmpv"); option(mpv, "ao", "null");
  option(mpv, "hwdec", "no"); option(mpv, "pause", "yes");
  option(mpv, "sub-font-size", "55");
  option(mpv, "sub-scale-by-window", argv[3]);
  option(mpv, "sub-scale-with-window", argv[4]);
  int status = mpv_initialize(mpv);
  if (status < 0) { fprintf(stderr, "init: %s\n", mpv_error_string(status)); return 2; }
  mpv_render_context *render = NULL;
  char api[] = MPV_RENDER_API_TYPE_SW;
  mpv_render_param create[] = {{MPV_RENDER_PARAM_API_TYPE, api}, {MPV_RENDER_PARAM_INVALID, NULL}};
  status = mpv_render_context_create(&render, mpv, create);
  if (status < 0) { fprintf(stderr, "create: %s\n", mpv_error_string(status)); return 2; }
  const char *command[] = {"loadfile", argv[1], NULL};
  status = mpv_command(mpv, command);
  if (status < 0) { fprintf(stderr, "load: %s\n", mpv_error_string(status)); return 2; }
  int ready = 0;
  for (int i = 0; i < 80 && !ready; ++i) {
    mpv_event *event = mpv_wait_event(mpv, 0.1);
    if (event->event_id == MPV_EVENT_FILE_LOADED) ready = 1;
    if (event->event_id == MPV_EVENT_END_FILE) { fprintf(stderr, "unexpected end file\n"); return 2; }
  }
  if (!ready) { fprintf(stderr, "file load timeout\n"); return 2; }
  const char *subcommand[] = {"sub-add", argv[2], "select", NULL};
  status = mpv_command(mpv, subcommand);
  if (status < 0) { fprintf(stderr, "sub-add: %s\n", mpv_error_string(status)); return 2; }
  int small = 0, tall = 0;
  for (int i = 0; i < 30 && (!small || !tall); ++i) {
    mpv_render_context_update(render);
    small = render_rows(render, 1280, 720);
    tall = render_rows(render, 1280, 900);
    if (!small || !tall) {
      struct timespec delay = {.tv_sec = 0, .tv_nsec = 100000000};
      nanosleep(&delay, NULL);
    }
  }
  printf("mode by-window=%s with-window=%s rows720=%d rows900=%d\n", argv[3], argv[4], small, tall);
  mpv_render_context_free(render);
  mpv_terminate_destroy(mpv);
  return small && tall ? 0 : 1;
}
