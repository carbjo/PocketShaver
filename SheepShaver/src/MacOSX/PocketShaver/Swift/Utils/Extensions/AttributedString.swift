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

	let regularFont: UIFont? // Only needed when used with LinkLabel, for calculating accurate position of link
	let boldAppearance: TextAppearance?
	let highlightedAppearance: TextAppearance?
	let images: [UIImage]?

	init(
		regularFont: UIFont? = nil,
		boldAppearance: TextAppearance? = nil,
		highlightedAppearance: TextAppearance? = nil,
		images: [UIImage]? = nil
	) {
		self.regularFont = regularFont
		self.boldAppearance = boldAppearance
		self.highlightedAppearance = highlightedAppearance
		self.images = images
	}
}

extension String {
	func withTagsReplaced(by config: StringTagConfig) -> NSAttributedString {
		return AttributedStringBuilder(string: self, config: config).build()
	}
}

private class AttributedStringBuilder {
	private let config: StringTagConfig

	private let attrString = NSMutableAttributedString()
	private var workString: String
	private var imagesIdx = 0

	init(
		string: String,
		config: StringTagConfig
	) {
		self.workString = string
		self.config = config
	}

	func build() -> NSAttributedString {
		var nextBoldTagIndex = nextIndexWithTag("<b>")
		var nextHighlightTagIndex = nextIndexWithTag("<mark>")
		var nextImageTagIndex = nextIndexWithTag("<img/>")

		var nextTagIndex = min(nextBoldTagIndex, nextHighlightTagIndex, nextImageTagIndex)

		while nextTagIndex != workString.endIndex {
			if nextBoldTagIndex == nextTagIndex {
				replaceNextBoldTag()
			} else if nextHighlightTagIndex == nextTagIndex {
				replaceNextHighlightedTag()
			} else if nextImageTagIndex == nextTagIndex {
				replaceNextImageTag()
			} else {
				fatalError()
			}

			nextBoldTagIndex = nextIndexWithTag("<b>")
			nextHighlightTagIndex = nextIndexWithTag("<mark>")
			nextImageTagIndex = nextIndexWithTag("<img/>")

			nextTagIndex = min(nextBoldTagIndex, nextHighlightTagIndex, nextImageTagIndex)
		}

		appendTextToAttrString(workString)

		return attrString
	}

	private func nextIndexWithTag(_ tag: String) -> String.Index {
		workString.range(of: tag)?.lowerBound ?? workString.endIndex
	}

	private func replaceNextBoldTag() {
		guard let boldAppearance = config.boldAppearance,
			  let beginningTagIndex = workString.range(of: "<b>"),
			  let endTagIndex = workString.range(of: "</b>") else {
			fatalError()
		}

		let prefix = String(workString[workString.startIndex..<beginningTagIndex.lowerBound])
		let boldPart = String(workString[beginningTagIndex.upperBound..<endTagIndex.lowerBound])

		appendTextToAttrString(prefix)
		attrString.append(
			.init(
				string: boldPart,
				attributes: [
					.font: boldAppearance.font,
					.foregroundColor: boldAppearance.color
				]
			)
		)

		workString = String(workString[endTagIndex.upperBound..<workString.endIndex])
	}

	private func replaceNextHighlightedTag() {
		guard let highlightedAppearance = config.highlightedAppearance,
			  let beginningTagIndex = workString.range(of: "<mark>"),
			  let endTagIndex = workString.range(of: "</mark>") else {
			fatalError()
		}

		let prefix = String(workString[workString.startIndex..<beginningTagIndex.lowerBound])
		let boldPart = String(workString[beginningTagIndex.upperBound..<endTagIndex.lowerBound])


		appendTextToAttrString(prefix)
		attrString.append(
			.init(
				string: boldPart,
				attributes: [
					.font: highlightedAppearance.font,
					.foregroundColor: highlightedAppearance.color
				]
			)
		)

		workString = String(workString[endTagIndex.upperBound..<workString.endIndex])
	}

	private func replaceNextImageTag() {
		guard let images = config.images,
			  let tagIndex = workString.range(of: "<img/>") else {
			fatalError()
		}

		let prefix = String(workString[workString.startIndex..<tagIndex.lowerBound])

		appendTextToAttrString(prefix)
		let imageAttachment = NSTextAttachment()
		imageAttachment.image = images[imagesIdx]
		attrString.append(.init(attachment: imageAttachment))

		imagesIdx += 1
		workString = String(workString[tagIndex.upperBound..<workString.endIndex])
	}

	private func appendTextToAttrString(_ string: String) {
		if let regularFont = config.regularFont {
			attrString.append(
				.init(
					string: string,
					attributes: [
						.font: regularFont
					]
				)
			)
		} else {
			attrString.append(.init(string: string))
		}
	}
}
