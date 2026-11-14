// MARK: Zenlygram — call recording. See SGOggFileDataItem.h.

#import "SGOggFileDataItem.h"

#import <errno.h>
#import <fcntl.h>
#import <unistd.h>

@interface SGOggFileDataItem () {
    int _fd;
    NSUInteger _writtenByteCount;
    BOOL _hasError;
}

@end

@implementation SGOggFileDataItem

- (instancetype _Nullable)initWithExistingFileAtPath:(NSString *)path {
    self = [super init];
    if (self != nil) {
        _fd = open([path fileSystemRepresentation], O_WRONLY | O_TRUNC);
        if (_fd < 0) {
            return nil;
        }
        _writtenByteCount = 0;
        _hasError = NO;
    }
    return self;
}

- (void)dealloc {
    [self closeFile];
}

- (void)appendData:(NSData *)data {
    if (_fd < 0 || _hasError || data.length == 0) {
        return;
    }
    // NSData may be discontiguous; -enumerateByteRangesUsingBlock: is the only correct way to walk it.
    __block BOOL failed = NO;
    __block NSUInteger written = 0;
    [data enumerateByteRangesUsingBlock:^(const void *bytes, NSRange byteRange, BOOL *stop) {
        if (failed) {
            *stop = YES;
            return;
        }
        const uint8_t *cursor = (const uint8_t *)bytes;
        size_t remaining = byteRange.length;
        while (remaining > 0) {
            ssize_t result = write(self->_fd, cursor, remaining);
            if (result <= 0) {
                if (result < 0 && errno == EINTR) {
                    continue;
                }
                failed = YES;
                *stop = YES;
                return;
            }
            cursor += result;
            remaining -= (size_t)result;
            written += (NSUInteger)result;
        }
    }];
    _writtenByteCount += written;
    if (failed) {
        _hasError = YES;
    }
}

- (NSData *)data {
    // Never used by the `beginWithDataItem:` path this feature takes; returning the file's contents
    // here would defeat the whole point of streaming it out of memory.
    return [NSData data];
}

- (NSUInteger)writtenByteCount {
    return _writtenByteCount;
}

- (BOOL)hasError {
    return _hasError;
}

- (void)closeFile {
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
    }
}

@end
