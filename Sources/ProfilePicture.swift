import Darwin
import Foundation
import ImageIO
import OpenDirectory
import UniformTypeIdentifiers

enum ProfilePictureError: LocalizedError {
    case invalidImage
    case accountMismatch
    case updateNotConfirmed

    var errorDescription: String? {
        switch self {
        case .invalidImage: "The matching profile icon could not be opened."
        case .accountMismatch: "The signed-in local Mac account could not be identified."
        case .updateNotConfirmed: "macOS did not confirm the new profile picture."
        }
    }
}

struct ProfilePicture {
    static func jpeg(from icon: URL) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]
        guard let source = CGImageSourceCreateWithURL(icon as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              thumbnail.width == thumbnail.height
        else { throw ProfilePictureError.invalidImage }

        let jpeg = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ProfilePictureError.invalidImage
        }
        CGImageDestinationAddImage(encoder, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw ProfilePictureError.invalidImage }
        return jpeg as Data
    }

    static func localAccount() throws -> ODRecord {
        let node = try ODNode(session: ODSession.default(), name: "/Local/Default")
        let uidAttribute = kODAttributeTypeUniqueID
        let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(),
                                     attributes: [uidAttribute, kODAttributeTypeJPEGPhoto])
        let values = try record.values(forAttribute: uidAttribute)
        guard let uid = values.first as? String, uid == String(getuid()), uid != "0" else {
            throw ProfilePictureError.accountMismatch
        }
        return record
    }
}

actor ProfilePictureUpdater {
    private var latestSelection = 0

    func apply(_ icon: URL, selection: Int) throws -> Bool {
        guard selection > latestSelection else { return false }
        latestSelection = selection
        let jpeg = try ProfilePicture.jpeg(from: icon)
        let account = try ProfilePicture.localAccount()
        let attribute = kODAttributeTypeJPEGPhoto
        try account.setValue(jpeg, forAttribute: attribute)
        try account.synchronize()
        let refreshed = try ProfilePicture.localAccount()
        guard try refreshed.values(forAttribute: attribute).first as? Data == jpeg else {
            throw ProfilePictureError.updateNotConfirmed
        }
        return true
    }
}
