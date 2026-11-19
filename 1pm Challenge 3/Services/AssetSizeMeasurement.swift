//
//  AssetSizeMeasurement.swift
//  1pm Challenge 3
//

import Foundation
import Photos

/// The single source of truth for how many bytes one photo-library asset takes
/// up. The Home snapshot and every overview scan both call this, so a category
/// total and the sum of its list can never disagree.
enum AssetSizeMeasurement {
    struct Measurement {
        var bytes: Int64
        var name: String
    }

    /// The resource that represents the asset the user sees. Videos use their
    /// full-size file; photos prefer the full-size original and fall back to
    /// the rendered photo.
    static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferredTypes: [PHAssetResourceType] = asset.mediaType == .video
            ? [.fullSizeVideo, .video]
            : [.fullSizePhoto, .photo]

        return preferredTypes
            .compactMap { type in resources.first { $0.type == type } }
            .first
    }

    /// Sums everything PhotoKit actually stores for the asset: the primary
    /// file, non-destructive edit data, the alternate representation of a
    /// RAW+JPEG pair, and the motion half of a Live Photo.
    static func measure(_ asset: PHAsset) -> Measurement? {
        guard let primary = primaryResource(for: asset),
              let primaryBytes = primary.measuredFileSize else {
            return nil
        }

        let isVideo = asset.mediaType == .video
        let resources = PHAssetResource.assetResources(for: asset)

        var bytes = primaryBytes

        let extraTypes: [PHAssetResourceType] = isVideo
            ? [.adjustmentData]
            : [.adjustmentData, .alternatePhoto]

        for type in extraTypes {
            if let resource = resources.first(where: { $0.type == type }),
               let size = resource.measuredFileSize {
                bytes += size
            }
        }

        if !isVideo, asset.mediaSubtypes.contains(.photoLive) {
            let pairedVideo = resources.first { $0.type == .fullSizePairedVideo }
                ?? resources.first { $0.type == .pairedVideo }

            if let size = pairedVideo?.measuredFileSize {
                bytes += size
            }
        }

        return Measurement(bytes: bytes, name: primary.originalFilename)
    }
}

extension PHAssetResource {
    /// PhotoKit does not publish a public size property. Reading the resource's
    /// `fileSize` key is the least invasive way to obtain the actual size;
    /// when it is unavailable the caller reports the category as estimated.
    var measuredFileSize: Int64? {
        let selector = NSSelectorFromString("fileSize")
        guard responds(to: selector),
              let number = value(forKey: "fileSize") as? NSNumber else {
            return nil
        }

        let size = number.int64Value
        return size > 0 ? size : nil
    }
}
