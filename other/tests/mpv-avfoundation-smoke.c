#include <mpv/client.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"failed: %s\n",#x); exit(1); } } while(0)
int main(int argc,char **argv){
 CHECK(argc==2); mpv_handle *h=mpv_create();CHECK(h);
 CHECK(mpv_set_option_string(h,"config","no")==0);
 CHECK(mpv_set_option_string(h,"load-scripts","no")==0);
 CHECK(mpv_set_option_string(h,"ao","avfoundation")==0);
 CHECK(mpv_set_option_string(h,"vo","null")==0);
 CHECK(mpv_set_option_string(h,"mute","yes")==0);
 CHECK(mpv_set_option_string(h,"pause","yes")==0);
 CHECK(mpv_initialize(h)==0);
 const char *load[]={"loadfile",argv[1],NULL}; CHECK(mpv_command(h,load)==0);
 int loaded=0;for(int i=0;i<100;i++){mpv_event *e=mpv_wait_event(h,.05);if(e->event_id==MPV_EVENT_FILE_LOADED){loaded=1;break;}} CHECK(loaded);
 for(int i=0;i<5;i++){
  int paused=0;CHECK(mpv_set_property(h,"pause",MPV_FORMAT_FLAG,&paused)==0);usleep(200000);
  char *ao=mpv_get_property_string(h,"current-ao");CHECK(ao);CHECK(!strcmp(ao,"avfoundation"));mpv_free(ao);
  double before=0,after=0;CHECK(mpv_get_property(h,"time-pos",MPV_FORMAT_DOUBLE,&before)==0);for(int wait=0;wait<60;wait++){usleep(50000);CHECK(mpv_get_property(h,"time-pos",MPV_FORMAT_DOUBLE,&after)==0);if(after>before+.01)break;}printf("cycle=%d before=%f after=%f\n",i,before,after);fflush(stdout);CHECK(after>before);
  paused=1;CHECK(mpv_set_property(h,"pause",MPV_FORMAT_FLAG,&paused)==0);usleep(100000);
 }
 int paused=0;CHECK(mpv_set_property(h,"pause",MPV_FORMAT_FLAG,&paused)==0);
 const char *seek[]={"seek","19.7","absolute+exact",NULL}; CHECK(mpv_command(h,seek)==0);
 int eof=0;for(int i=0;i<160;i++){mpv_event *event=mpv_wait_event(h,.05);if(event->event_id==MPV_EVENT_END_FILE){mpv_event_end_file *end=event->data;if(end->reason==MPV_END_FILE_REASON_EOF){eof=1;break;}}}CHECK(eof);
 CHECK(mpv_command(h,load)==0);usleep(200000);const char *stop[]={"stop",NULL};CHECK(mpv_command(h,stop)==0);
 mpv_terminate_destroy(h);puts("PASS: rebuilt libmpv AVFoundation output, five pause/resume cycles with advancing audio, EOF, reopen and stop");
}
