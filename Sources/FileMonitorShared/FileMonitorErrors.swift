//
// aus der Technik, on 27.12.24.
// https://www.ausdertechnik.de
//

import Foundation

/// Errors that `FileMonitor` can throw
public enum FileMonitorErrors: Error {
    case unsupported_os
    case not_implemented_yet
    case not_a_directory(url: URL)
    case can_not_open(url: URL)
}
