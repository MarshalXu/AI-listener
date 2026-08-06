#import "ObjCExceptionBridge.h"

BOOL ALExceptionTry(void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"AIListener.ObjCExceptionBridge"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    exception.name ?: @"NSException",
                NSLocalizedFailureReasonErrorKey:
                    exception.reason ?: @""
            }];
        }
        return NO;
    }
}
