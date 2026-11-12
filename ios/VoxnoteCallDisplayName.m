#import "VoxnoteCallDisplayName.h"
#import <libPhoneNumber_iOS/NBPhoneNumberUtil.h>

NSString *VoxnoteCallDisplayName(NSString *value) {
    // Only canonical international numbers are eligible. Names, private callers,
    // client identities, short codes, and already formatted labels stay intact.
    if (value == nil || [value rangeOfString:@"^\\+[1-9][0-9]{7,14}$"
                                   options:NSRegularExpressionSearch].location == NSNotFound) {
        return value;
    }

    NBPhoneNumberUtil *formatter = [NBPhoneNumberUtil sharedInstance];
    NSError *error = nil;
    NBPhoneNumber *number = [formatter parse:value defaultRegion:@"ZZ" error:&error];
    if (error != nil || number == nil || ![formatter isValidNumber:number]) {
        return value;
    }

    NSString *label = [formatter format:number
                          numberFormat:NBEPhoneNumberFormatINTERNATIONAL
                                 error:&error];
    return error == nil && label.length > 0 ? label : value;
}
