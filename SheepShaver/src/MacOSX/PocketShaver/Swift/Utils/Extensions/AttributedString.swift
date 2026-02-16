//
//  AttributedString.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-01-25.
//

import UIKit

struct StringTagConfig {
	struct TextAppearance {
		let font: UIFont
		let color: UIColor
	}

	let boldAppearance: TextAppearance?
	let highlightedAppearance: TextAppearance?
	let images: [UIImage]?
	let highlightedImages: [UIImage]?

	init(
		boldAppearance: TextAppearance? = .init(font: .boldSystemFont(ofSize: 14), color: Colors.primaryText),
		highlightedAppearance: TextAppearance? = .init(font: .boldSystemFont(ofSize: 14), color: Colors.highlightedText),
		images: [UIImage]? = nil,
		highlightedImages: [UIImage]? = nil
	) {
		self.boldAppearance = boldAppearance
		self.highlightedAppearance = highlightedAppearance
		self.images = images
		self.highlightedImages = highlightedImages
	}
}

extension String {
	func withTagsReplaced(
		by config: StringTagConfig,
		regularFont: UIFont? = nil
	) -> NSAttributedString {
		return AttributedStringBuilder(
			string: self,
			config: config,
			regularFont: regularFont
		).build()
	}
}

private class AttributedStringBuilder {
	private let config: StringTagConfig
	private let regularFont: UIFont?

	private let workString: String
	private var imagesIdx = 0

	init(
		string: String,
		config: StringTagConfig,
		regularFont: UIFont?
	) {
		self.workString = string
		self.config = config
		self.regularFont = regularFont
	}

	func build() -> NSAttributedString {
		return process(workString, tag: nil)
	}

	private func process(_ string: String, tag: AttributedStringBuilderTagMetadata?) -> NSAttributedString {
		var attributes: [NSAttributedString.Key : Any]?

		if let tag {
			switch tag.type {
			case .bold:
				if let boldAppearance = config.boldAppearance {
					attributes = [
						.font: boldAppearance.font,
						.foregroundColor: boldAppearance.color
					]
				}
			case .highlight:
				if let highlightedAppearance = config.highlightedAppearance {
					attributes = [
						.font: highlightedAppearance.font,
						.foregroundColor: highlightedAppearance.color
					]
				}
			case .image, .highlightedImage:
				fatalError()
			}
		} else if let regularFont {
			attributes = [
				.font: regularFont
			]
		}

		var workString = string

		let outputString = NSMutableAttributedString()
		while let nextTag = nextTag(workString) {
			let prefix = String(workString[workString.startIndex..<nextTag.start.lowerBound])
			outputString.append(.init(string: prefix, attributes: attributes))

			switch nextTag.type {
			case .image:
				let tagString = String(workString[nextTag.start.lowerBound..<nextTag.end.upperBound])
				outputString.append(processImage(tagString: tagString))
			case .highlightedImage:
				let tagString = String(workString[nextTag.start.lowerBound..<nextTag.end.upperBound])
				outputString.append(processHighligtedImage(tagString: tagString))
			default:
				let taggedString = String(workString[nextTag.start.upperBound..<nextTag.end.lowerBound])
				outputString.append(process(taggedString, tag: nextTag))
			}

			workString = String(workString[nextTag.end.upperBound..<workString.endIndex])
		}

		let postfix = workString
		outputString.append(.init(string: postfix, attributes: attributes))

		return outputString
	}

	private func processImage(tagString: String) -> NSAttributedString {
		guard let images = config.images,
			  let tagPrefix = tagString.range(of: "<img"),
			  let tagPostfix = tagString.range(of: "/>") else {
			fatalError()
		}

		let parametersString = String(tagString[tagPrefix.upperBound..<tagPostfix.lowerBound])
		let imageAttachment = createTextAttachment(with: images[imagesIdx], parametersString: parametersString)

		imagesIdx += 1

		return .init(attachment: imageAttachment)
	}

	private func processHighligtedImage(tagString: String) -> NSAttributedString {
		guard let images = config.highlightedImages,
			  let tagPrefix = tagString.range(of: "<imgmark"),
			  let tagPostfix = tagString.range(of: "/>") else {
			fatalError()
		}

		let parametersString = String(tagString[tagPrefix.upperBound..<tagPostfix.lowerBound])
		let imageAttachment = createTextAttachment(with: images[imagesIdx], parametersString: parametersString)

		imagesIdx += 1

		return .init(attachment: imageAttachment)
	}

	private func createTextAttachment(with image: UIImage, parametersString: String) -> NSTextAttachment {
		let imageAttachment = NSTextAttachment()
		imageAttachment.image = image
		if let yOffsetParameterPrefix = parametersString.range(of: "yOffset=") {
			let yOffsetString = parametersString[yOffsetParameterPrefix.upperBound..<parametersString.endIndex]
			let yOffset = CGFloat(Float(yOffsetString) ?? 0)

			imageAttachment.bounds = .init(x: 0, y: yOffset, width: image.size.width, height: image.size.height)
		}
		return imageAttachment
	}

	private func nextTag(_ string: String) -> AttributedStringBuilderTagMetadata? {
		let nextBoldTag = string.range(of: "<b>")
		let nextHighlightTag = string.range(of: "<mark>")
		let nextImageTag = string.range(of: StringTagConfig.imageTagRegex, options: .regularExpression)
		let nextHighlightedImageTag = string.range(of: StringTagConfig.highlightedImageTagRegex, options: .regularExpression)

		let nextTagIndex = min(
			nextBoldTag?.lowerBound ?? string.endIndex,
			nextHighlightTag?.lowerBound ?? string.endIndex,
			nextImageTag?.lowerBound ?? string.endIndex,
			nextHighlightedImageTag?.lowerBound ?? string.endIndex
		)

		guard nextTagIndex != string.endIndex else {
			return nil
		}

		if nextTagIndex == nextBoldTag?.lowerBound {
			let endTag = string.range(of: "</b>")!
			return .init(start: nextBoldTag!, end: endTag, type: .bold)
		} else if nextTagIndex == nextHighlightTag?.lowerBound {
			let endTag = string.range(of: "</mark>")!
			return .init(start: nextHighlightTag!, end: endTag, type: .highlight)
		} else if nextTagIndex == nextImageTag?.lowerBound {
			return .init(start: nextImageTag!, end: nextImageTag!, type: .image)
		} else if nextTagIndex == nextHighlightedImageTag?.lowerBound {
			return .init(start: nextHighlightedImageTag!, end: nextHighlightedImageTag!, type: .highlightedImage)
		} else {
			return nil
		}
	}
}

fileprivate struct AttributedStringBuilderTagMetadata {
	enum TagType {
		case bold
		case highlight
		case image
		case highlightedImage
	}

	let start: Range<String.Index>
	let end: Range<String.Index>
	let type: TagType
}

extension StringTagConfig {
	static let imageTagRegex = "(<img)( yOffset=)*[-0123456789]*(/>)"
	static let highlightedImageTagRegex = "(<imgmark)( yOffset=)*[-0123456789]*(/>)"
}
