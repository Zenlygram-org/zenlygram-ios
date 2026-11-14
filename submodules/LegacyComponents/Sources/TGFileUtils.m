#import <LegacyComponents/TGFileUtils.h>

#import <MobileCoreServices/MobileCoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSString *TGMimeTypeForFileExtension(NSString *fileExtension)
{
    if (@available(iOS 14.0, *)) {
        NSString *mimeType = fileExtension != nil ? [UTType typeWithFilenameExtension:fileExtension].preferredMIMEType : nil;
        return mimeType ?: @"application/octet-stream";
    } else {
        return TGMimeTypeForFileUTI((__bridge_transfer NSString *)UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)fileExtension, NULL));
    }
}

NSString *TGMimeTypeForFileUTI(NSString *fileUTI)
{
    NSString *mimeType;
    if (@available(iOS 14.0, *)) {
        mimeType = fileUTI != nil ? [UTType typeWithIdentifier:fileUTI].preferredMIMEType : nil;
    } else {
        mimeType = (__bridge_transfer NSString *)UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)fileUTI, kUTTagClassMIMEType);
    }
    if (mimeType == nil)
        mimeType = @"application/octet-stream";
    return mimeType;
}

NSString *TGTemporaryFileName(NSString *fileExtension)
{
    if (fileExtension == nil)
        fileExtension = @"bin";
    
    int64_t randomId = 0;
    arc4random_buf(&randomId, sizeof(randomId));
    
    return [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSString alloc] initWithFormat:@"%" PRIx64 ".%@", randomId, fileExtension]];
}
