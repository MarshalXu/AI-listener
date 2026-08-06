#ifndef OBJC_EXCEPTION_BRIDGE_H
#define OBJC_EXCEPTION_BRIDGE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the given block inside an Objective-C @try/@catch handler.
///
/// AVAudioEngine's `installTapOnBus:bufferSize:format:block:` and
/// `start` raise an Objective-C `NSException` (not a Swift `Error`) when
/// the audio route/format is not ready (notably Bluetooth HFP/A2DP routes
/// that are still being negotiated). Swift's `do/catch` cannot catch an
/// `NSException`, so an unhandled exception terminates the process via
/// `objc_exception_throw` -> `std::terminate` -> `abort()`.
///
/// This bridge wraps the block in `@try/@catch` and, on a caught
/// exception, produces an `NSError` so the caller can surface a Swift
/// `Error` and recover gracefully instead of crashing.
///
/// - Parameters:
///   - block: the Objective-C-throwing operation to run.
///   - error: populated with the caught exception (name + reason) when
///     the block raises; untouched on success.
/// - Returns: `YES` if the block returned without raising; `NO` if an
///   `NSException` was caught and `error` was populated.
BOOL ALExceptionTry(void (^_Nonnull block)(void), NSError **_Nullable error);

NS_ASSUME_NONNULL_END

#endif /* OBJC_EXCEPTION_BRIDGE_H */
