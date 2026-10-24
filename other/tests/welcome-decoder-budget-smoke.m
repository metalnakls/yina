#import <Cocoa/Cocoa.h>
#import "FFmpegController.h"
#import <stdatomic.h>
static atomic_int running, peak, finished;
@interface FFmpegLogger:NSObject
+ (void)debug:(NSString*)value;
+ (void)warn:(NSString*)value;
+ (void)error:(NSString*)value;
@end
@implementation FFmpegLogger
+ (void)debug:(NSString*)value {} + (void)warn:(NSString*)value {} + (void)error:(NSString*)value {}
@end
@interface SlowDecoder:FFmpegController
@end
@implementation SlowDecoder
// Substitute slow decode work at the real production operation-queue seam.
- (int)getPeeksForFile:(NSString*)file thumbnailsWidth:(int)width requestedTime:(double)time operation:(NSOperation*)operation {
  int count=atomic_fetch_add(&running,1)+1;
  int prior=atomic_load(&peak);
  while(count>prior && !atomic_compare_exchange_weak(&peak,&prior,count)){}
  usleep(100000);
  atomic_fetch_sub(&running,1);
  return 0;
}
@end
@interface Results:NSObject<FFmpegControllerDelegate>
@end
@implementation Results
- (void)didUpdateThumbnails:(NSArray*)frames forFile:(NSString*)file withProgress:(NSInteger)progress {}
- (void)didGenerateThumbnails:(NSArray*)frames forFile:(NSString*)file succeeded:(BOOL)success {atomic_fetch_add(&finished,1);}
@end
int main(void) {@autoreleasepool {
  Results *results=[Results new];NSMutableArray *controllers=[NSMutableArray array];
  for(int i=0;i<12;i++){
    SlowDecoder *controller=[SlowDecoder new];controller.delegate=results;[controllers addObject:controller];
    [controller generateThumbnailForFile:@"synthetic" atTime:0 thumbWidth:960];
  }
  NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
  while(atomic_load(&finished)<12 && [deadline timeIntervalSinceNow]>0)
    [[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  int maximum=atomic_load(&peak);
  printf("Preview decoders: peak=%d completed=%d\n",maximum,atomic_load(&finished));
  if(maximum>2 || atomic_load(&finished)!=12)return 1;
  // Cancel both active and waiting decoders; their permits must remain reusable.
  atomic_store(&finished,0);
  [controllers removeAllObjects];
  for(int i=0;i<12;i++){
    SlowDecoder *controller=[SlowDecoder new];controller.delegate=results;[controllers addObject:controller];
    [controller generateThumbnailForFile:@"synthetic" atTime:0 thumbWidth:960];
  }
  deadline=[NSDate dateWithTimeIntervalSinceNow:2];
  while(atomic_load(&running)<2 && [deadline timeIntervalSinceNow]>0)
    [[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
  NSDate *cancelStart=[NSDate date];
  for(FFmpegController *controller in controllers)[controller cancelThumbnailGeneration];
  if(-[cancelStart timeIntervalSinceNow]>0.05)return 2;
  SlowDecoder *fresh=[SlowDecoder new];fresh.delegate=results;[controllers addObject:fresh];
  [fresh generateThumbnailForFile:@"synthetic" atTime:0 thumbWidth:960];
  deadline=[NSDate dateWithTimeIntervalSinceNow:2];
  while(atomic_load(&finished)<1 && [deadline timeIntervalSinceNow]>0)
    [[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  if(atomic_load(&finished)!=1 || atomic_load(&peak)>2)return 3;
  puts("PASS: bounded preview work, nonblocking cancellation and reusable decoder permits");
  return 0;
}}
