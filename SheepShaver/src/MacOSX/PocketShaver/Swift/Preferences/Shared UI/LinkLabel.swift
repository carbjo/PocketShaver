//
//  LinkLabel.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-11-17.
//

import UIKit

class LinkLabel: UIView {
	private(set) lazy var label: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		return label
	}()

	private let plaintext: String
	private let linkRange: Range<String.Index>?
	private let nonHighlightedString: NSAttributedString
	private let highlightedString: NSAttributedString
	private let callback: (() -> Void)?

	private var isTouching = false

	init(
		text: String,
		config: StringTagConfig,
		font: UIFont = .systemFont(ofSize: 14),
		textColor: UIColor = Colors.secondaryText,
		textAlignment: NSTextAlignment = .left,
		callback: (() -> Void)? = nil
	) {
		self.callback = callback

		(self.linkRange, self.plaintext) = Self.getLinkRangeAndCleanString(text)

		nonHighlightedString = Self.attributedString(
			text: text,
			config: config,
			regularFont: font,
			withHighlight: false
		)
		highlightedString = Self.attributedString(
			text: text,
			config: config,
			regularFont: font,
			withHighlight: true
		)

		super.init(frame: .zero)

		label.font = font
		label.textColor = textColor
		label.textAlignment = textAlignment

		addSubview(label)

		NSLayoutConstraint.activate([
			label.leadingAnchor.constraint(equalTo: leadingAnchor),
			label.topAnchor.constraint(equalTo: topAnchor),
			label.trailingAnchor.constraint(equalTo: trailingAnchor),
			label.bottomAnchor.constraint(equalTo: bottomAnchor)
		])

		label.attributedText = nonHighlightedString

		translatesAutoresizingMaskIntoConstraints = false
	}

	required init?(coder: NSCoder) { fatalError() }

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesBegan(touches, with: event)

		guard let touch = touches.first else {
			return
		}

		let location = touch.location(in: self)

		if isInsideLinkArea(location) {
			label.attributedText = highlightedString

			isTouching = true
		}
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesMoved(touches, with: event)

		guard let touch = touches.first else {
			return
		}

		let location = touch.location(in: self)

		if isInsideLinkArea(location) {
			label.attributedText = highlightedString
		} else {
			label.attributedText = nonHighlightedString
		}
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesEnded(touches, with: event)

		label.attributedText = nonHighlightedString

		if isTouching {
			callback?()
		}

		isTouching = false
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesCancelled(touches, with: event)

		label.attributedText = nonHighlightedString

		isTouching = false
	}

	private func isInsideLinkArea(_ point: CGPoint) -> Bool {
		guard let linkRange else {
			return false
		}
		
		let nsRange = NSRange(linkRange, in: plaintext)
		guard let frame = label.boundingRect(forCharacterRange: nsRange) else {
			return false
		}

		return frame.contains(point)
	}

	private static func getLinkRangeAndCleanString(_ string: String) -> (Range<String.Index>?, String) {
		var workString = string
		workString = workString.replacingOccurrences(of: "<b>", with: "")
		workString = workString.replacingOccurrences(of: "</b>", with: "")
		workString = workString.replacingOccurrences(of: "<mark>", with: "")
		workString = workString.replacingOccurrences(of: "</mark>", with: "")
		workString = workString.replacingOccurrences(of: StringTagConfig.imageTagRegex, with: " ", options: .regularExpression)

		var range: Range<String.Index>?
		if let lowerBound = workString.range(of: "<link>")?.lowerBound {
			workString = workString.replacingOccurrences(of: "<link>", with: "")
			let upperBound = workString.range(of: "</link>")!.lowerBound
			workString = workString.replacingOccurrences(of: "</link>", with: "")
			range = lowerBound..<upperBound
		}

		return (range, workString)
	}

	private static func attributedString(
		text: String,
		config: StringTagConfig,
		regularFont: UIFont,
		withHighlight: Bool
	) -> NSAttributedString {
		let tagConvertedText: String
		if withHighlight {
			var text = text

			if  let beginTagRange = text.range(of: "<link>"),
				let endTagRange = text.range(of: "</link>") {
				text = text
					.replacingOccurrences(of: "<img", with: "<imgmark", range: beginTagRange.upperBound..<endTagRange.lowerBound)
			}

			tagConvertedText = text
				.replacingOccurrences(of: "<link>", with: "<mark>")
				.replacingOccurrences(of: "</link>", with: "</mark>")
		} else {
			tagConvertedText = text
				.replacingOccurrences(of: "<link>", with: "<b>")
				.replacingOccurrences(of: "</link>", with: "</b>")
		}

		return tagConvertedText.withTagsReplaced(
			by: config,
			regularFont: regularFont
		)
	}
}

private extension UILabel {
	func boundingRect(forCharacterRange range: NSRange) -> CGRect? {
		guard let attributedText else {
			return nil
		}

		let textStorage = NSTextStorage(attributedString: attributedText)
		let layoutManager = NSLayoutManager()

		textStorage.addLayoutManager(layoutManager)

		let textContainer = NSTextContainer(size: bounds.size)
		textContainer.lineFragmentPadding = 0.0

		layoutManager.addTextContainer(textContainer)

		var glyphRange = NSRange()

		// Convert the range for glyphs.
		layoutManager.characterRange(forGlyphRange: range, actualGlyphRange: &glyphRange)

		let originalBoundingRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

		let adjustedBoundingRect = CGRect(
			origin: .init(
				x: originalBoundingRect.origin.x - 30,
				y: originalBoundingRect.origin.y - 30
			),
			size: .init(
				width: originalBoundingRect.size.width + 60,
				height: originalBoundingRect.size.height + 60
			)
		)

		return adjustedBoundingRect
	}
}
