#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSDictionary *CCChess(NSDictionary *request, NSString *networkPath);
FOUNDATION_EXPORT void CCStop(void);
FOUNDATION_EXPORT NSDictionary *CCPuzzle(NSDictionary *request);

FOUNDATION_EXPORT uint64_t CCBackgroundEpoch(void);
FOUNDATION_EXPORT void CCStopBackground(void);
