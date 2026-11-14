// MARK: Zenlygram — call recording.
//
// `TGOggOpusWriter` writes its Ogg pages into a `TGDataItem`, which upstream implements as a plain
// in-memory `NSMutableData` with no file backing and no way to truncate
// (submodules/OpusBinding/Sources/TGDataItem.m). A one-hour call would therefore sit in RAM in its
// entirety, twice (one stream per direction), and never be flushed.
//
// This subclass keeps the writer's contract (`-appendData:`) and sends every page straight to an
// already-open file descriptor instead. `-data` deliberately returns an empty NSData: the writer
// only reads it in the `beginAppendWithDataItem:` path, which call recording never takes.
//
// It lives in Objective-C rather than Swift on purpose — subclassing across the Swift/ObjC bridge
// would depend on how the importer renames `appendData:`/`data`, and a rename would silently turn
// the override into a new, never-called method.

#import <Foundation/Foundation.h>

#import <OpusBinding/TGDataItem.h>

NS_ASSUME_NONNULL_BEGIN

@interface SGOggFileDataItem : TGDataItem

/// Total number of bytes handed to the file so far.
@property (nonatomic, readonly) NSUInteger writtenByteCount;
/// YES once any write failed (disk full, protected-data unavailable, ...). The recording is then
/// abandoned rather than silently truncated.
@property (nonatomic, readonly) BOOL hasError;

/// The file at `path` must already exist — it is created by the Swift side with its data-protection
/// class set at creation time, which is the only way the class applies to the very first byte.
/// Returns nil if the file cannot be opened for writing.
- (instancetype _Nullable)initWithExistingFileAtPath:(NSString *)path;

- (void)closeFile;

@end

NS_ASSUME_NONNULL_END
