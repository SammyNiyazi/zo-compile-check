import Foundation

extension Error {
    /// "No such file" in every form Foundation reports it: Cocoa read (260),
    /// Cocoa no-such-file (4) or POSIX ENOENT, also when wrapped as the
    /// underlying error. FileHandle on iOS 26 reports the POSIX form, which
    /// made an empty history look unreadable (9 Oct compile check).
    var isMissingFile: Bool {
        let error = self as NSError
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return underlying.isMissingFile }
        return false
    }
}
