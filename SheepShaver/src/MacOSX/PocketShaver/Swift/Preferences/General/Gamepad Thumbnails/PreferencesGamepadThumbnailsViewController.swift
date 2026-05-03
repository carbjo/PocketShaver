//
//  PreferencesGamepadThumbnailsViewController.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-04-25.
//

import UIKit

class PreferencesGamepadThumbnailsViewController: UIViewController {
	private lazy var collectionView: UICollectionView = {
		let layout = PreferencesGeneralGamepadThumbnailCollectionViewLayout()

		let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
		collectionView.translatesAutoresizingMaskIntoConstraints = false
		collectionView.backgroundColor = .clear
		collectionView.showsHorizontalScrollIndicator = false
		collectionView.allowsSelection = false
		collectionView.register(
			PreferencesGeneralGamepadThumbnailCell.self,
			forCellWithReuseIdentifier: PreferencesGeneralGamepadThumbnailCell.reuseIdentifier
		)
		collectionView.register(
			PreferencesGeneralGamepadThumbnailSpacingCell.self,
			forCellWithReuseIdentifier: PreferencesGeneralGamepadThumbnailSpacingCell.reuseIdentifier
		)
		return collectionView
	}()

	private lazy var emptyStateLabel: UILabel = {
		let label = UILabel.withoutConstraints()
		label.text = "No gamepad overlays saved"
		label.font = .boldSystemFont(ofSize: 18)
		label.textColor = Colors.primaryText
		return label
	}()

	private lazy var gradientView: GradientView = {
		let view = GradientView.withoutConstraints()
		view.isUserInteractionEnabled = false
		return view
	}()

	private let gamepadConfigs: [GamepadConfig]

	init(
		gamepadConfigs: [GamepadConfig]
	) {
		self.gamepadConfigs = gamepadConfigs

		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) { fatalError() }

	override func viewDidLoad() {
		super.viewDidLoad()

		setupViews()
		updateData()
	}

	override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
		super.traitCollectionDidChange(previousTraitCollection)

		gradientView.updateColors()
	}

	func setRightInset(_ inset: CGFloat) {
		collectionView.contentInset = .init(top: 0, left: 0, bottom: 0, right: inset)
	}

	private func setupViews() {
		view.translatesAutoresizingMaskIntoConstraints = false

		view.backgroundColor = Colors.primaryBackground

		view.addSubview(collectionView)
		view.addSubview(gradientView)
		view.addSubview(emptyStateLabel)

		NSLayoutConstraint.activate([
			collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
			collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

			collectionView.heightAnchor.constraint(equalToConstant: 56),
			collectionView.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
			collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),

			gradientView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			gradientView.topAnchor.constraint(equalTo: view.topAnchor),
			gradientView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			gradientView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

			emptyStateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			emptyStateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
		])
	}

	private func updateData() {
		let isEmpty = gamepadConfigs.isEmpty
		collectionView.isHidden = isEmpty
		emptyStateLabel.isHidden = !isEmpty

		collectionView.dataSource = self
		collectionView.delegate = self

		collectionView.reloadData()
	}
}

extension PreferencesGamepadThumbnailsViewController: UICollectionViewDataSource {
	func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
		guard !gamepadConfigs.isEmpty else {
			return 0
		}
		return (gamepadConfigs.count * 2) - 1
	}

	func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {

		let index = indexPath.item

		if index % 2 == 0 { // Even --> Gamepad cell
			let cell = collectionView.dequeueReusableCell(
				withReuseIdentifier: PreferencesGeneralGamepadThumbnailCell.reuseIdentifier,
				for: indexPath
			)
			if let tile = cell as? PreferencesGeneralGamepadThumbnailCell {
				let gamepadIndex = index / 2

				let layoutImage = GamepadThumbnailCache.shared.image(for: gamepadConfigs[gamepadIndex])

				tile.configure(
					name: gamepadConfigs[gamepadIndex].name,
					layoutImage: layoutImage
				)
			}
			return cell
		} else { // Odd --> Spacing cell
			let cell = collectionView.dequeueReusableCell(
				withReuseIdentifier: PreferencesGeneralGamepadThumbnailSpacingCell.reuseIdentifier,
				for: indexPath
			)
			return cell
		}
	}
}

extension PreferencesGamepadThumbnailsViewController: UICollectionViewDelegate {
	func scrollViewDidScroll(_ scrollView: UIScrollView) {
		let contentOffset = scrollView.contentOffset.x
		let contentSize = scrollView.contentSize.width + scrollView.contentInset.right
		let frameSize = scrollView.frame.size.width

		let percentage = contentOffset / (contentSize - frameSize)
		let clampedPercentage = max(0, min(1, percentage))

		gradientView.alpha = 1 - clampedPercentage
	}
}
