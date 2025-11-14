//
//  LinkLabel.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-11-17.
//

import UIKit

class LinkLabel: UIView {
	private lazy var label: UILabel = {
		let label = UILabel.withoutConstraints()
		label.numberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.font = .systemFont(ofSize: 14)
		label.textColor = .darkGray
		return label
	}()

	private let text: String
	private let linkRange: Range<String.Index>
	private let nonHighlightedString: NSAttributedString
	private let highlightedString: NSAttributedString
	private let callback: (() -> Void)

	private var isTouching = false

	init(
		text: String,
		linkRange: Range<String.Index>,
		callback: @escaping (() -> Void)
	) {
		self.text = text
		self.linkRange = linkRange
		nonHighlightedString = Self.attributedString(text: text, linkRange: linkRange, withHighlight: false)
		highlightedString = Self.attributedString(text: text, linkRange: linkRange, withHighlight: true)
		self.callback = callback

		super.init(frame: .zero)

		addSubview(label)

		NSLayoutConstraint.activate([
			label.leadingAnchor.constraint(equalTo: leadingAnchor),
			label.topAnchor.constraint(equalTo: topAnchor),
			label.trailingAnchor.constraint(equalTo: trailingAnchor),
			label.bottomAnchor.constraint(equalTo: bottomAnchor)
		])

		label.attributedText = nonHighlightedString
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
			callback()
		}

		isTouching = false
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesCancelled(touches, with: event)

		label.attributedText = nonHighlightedString

		isTouching = false
	}

	private func isInsideLinkArea(_ point: CGPoint) -> Bool {
		let nsRange = NSRange(linkRange, in: text)
		guard let frame = label.boundingRect(forCharacterRange: nsRange) else {
			return false
		}

		return frame.contains(point)

//		let view = UIView(frame: frame!)
//		view.backgroundColor = UIColor(red: 0.3, green: 0.4, blue: 0.2, alpha: 0.3)
//		addSubview(view)
//		print("-- frame: \(frame!)")
	}

	private static func attributedString(
		text: String,
		linkRange: Range<String.Index>,
		withHighlight: Bool
	) -> NSAttributedString {
		let attrString = NSMutableAttributedString()

		let prefix = String(text[text.startIndex..<linkRange.lowerBound])
		let boldPart = String(text[linkRange.lowerBound..<linkRange.upperBound])
		let postfix = String(text[linkRange.upperBound..<text.endIndex])

		attrString.append(
			.init(
				string: prefix,
				attributes: [
					.font: UIFont.systemFont(ofSize: 14),
				]
			)
		)
		attrString.append(
			.init(
				string: boldPart,
				attributes: [
					.font: UIFont.boldSystemFont(ofSize: 14),
					.foregroundColor: withHighlight ? UIColor.lightGray : UIColor.black
				]
			)
		)
		attrString.append(
			.init(
				string: postfix,
				attributes: [
					.font: UIFont.systemFont(ofSize: 14),
				]
			)
		)

		return attrString
	}
}

private extension UILabel {
	func boundingRect(forCharacterRange range: NSRange) -> CGRect? {

		guard let attributedText = attributedText else { return nil }

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
