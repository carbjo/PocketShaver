//
//  DiskFileExtractor.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-15.
//

class DiskFileExtractor {
	private static let supportedFileExtensions = ["dsk", "cdr", "iso", "toast", "img"]

	static func extractFile(fromDiskUrl fromUrl: URL, to toUrl: URL, quarryNameOrPath: String) -> Bool {
		let pathExtension = fromUrl.pathExtension.lowercased()
		guard supportedFileExtensions.contains(pathExtension) else {
			return false
		}

		let extractor = ImpHFSExtractor()
		extractor.sourceDevice = fromUrl
		extractor.quarryNameOrPath = quarryNameOrPath
		extractor.shouldCopyToDestination = true
		extractor.destinationPath = toUrl.path

		var error: NSError?
		extractor.performExtractionOrReturnError(&error)

		if let error {
			print("- Extraction error \(error)")
		}

		return error == nil
	}

	static func extractRom(fromDiskUrl fromUrl: URL, to toUrl: URL) -> Bool {
		if extractFile(fromDiskUrl: fromUrl, to: toUrl, quarryNameOrPath: ":System Folder:Mac OS ROM") {
			return true
		}

		print("- Extracting from absolute path failed. Trying full search.")

		return extractFile(fromDiskUrl: fromUrl, to: toUrl, quarryNameOrPath: "Mac OS ROM")
	}
}
