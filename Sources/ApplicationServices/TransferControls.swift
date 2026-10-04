import Foundation

extension AppModel {
    public func setTransfersSuspended(upload: Bool, _ suspended: Bool) async {
        if upload { uploadsSuspended = suspended } else { downloadsSuspended = suspended }
        await transferEngine.setSuspended(upload: upload, suspended)
    }
}
