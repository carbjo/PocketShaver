//
//  PreferencesGeneralCreateDiskViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

import UIKit
import Combine

class PreferencesGeneralViewController: UITableViewController {
	enum Section {
		case setupInstructions
		case bootstrap
		case disks
		case audio
		case iPadMouse
		case twoFingerSteering
		case rightClick
		case keyboardAutoOffset
		case hapticFeedback
		case hints
	}

	enum Row: Hashable {
		// setupInstructions
		case setupInstructions

		// bootstrap
		case bootstrap
		case bootstrapError

		// disks
		case disksColumnDescription
		case disksEmptyState
		case disksDisk(PreferencesGeneralModel.DiskEntry)
		case disksActions
		case disksError

		// audio
		case audioEnabledToggle
		case audioInformation

		// iPadMouse
		case iPadMouse

		// twoFingerSteering
		case twoFingerSteeringInformation
		case twoFingerSteeringEnabledToggle(Bool)
		case twoFingerSteeringSettings(PreferencesGeneralModel.TwoFingerSteeringSettings)

		// rightClick
		case rightClick
		case rightClickInformation

		// keyboardAutoOffset
		case keyboardAutoOffset
		case keyboardAutoOffsetInformation

		// hapticFeedback
		case hapticFeedbackSwipeGesturesToggle
		case hapticFeedbackMouseClicksToggle
		case hapticFeedbackGamepadKeyStrokesToggle

		// hints
		case hintsToggle
		case hintsInformation
	}

	enum FilePickerSource: Int {
		case romSelection
		case fileImport
	}

	private let model: PreferencesGeneralModel
	private let createDiskDialogueFactory = PreferencesGeneralCreateDiskDialogueFactory()

	private var anyCancellables = Set<AnyCancellable>()

	private var dataSource: TableViewDiffableDataSource<Section, Row>!

	private let segmentedControlFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

	init(
		mode: PreferencesLaunchMode,
		changeSubject: PassthroughSubject<PreferencesChange, Never>
	) {
		model = .init(
			mode: mode,
			changeSubject: changeSubject
		)

		super.init(nibName: nil, bundle: nil)

		view.backgroundColor = Colors.primaryBackground
	}

	required init?(coder: NSCoder) { fatalError() }

	override func viewDidLoad() {
		super.viewDidLoad()

		view.translatesAutoresizingMaskIntoConstraints = false

		tableView.showsVerticalScrollIndicator = false
		tableView.delaysContentTouches = false
		PreferencesGeneralDiskCell.register(in: tableView)

		setupDataSource()
		listenToChanges()
	}

	private func listenToChanges() {
		NotificationCenter.default.addObserver(self, selector: #selector(appDidResume), name: UIScene.didActivateNotification, object: nil)
	}

	private func setupDataSource() {
		dataSource = .init(tableView: tableView) { [weak self] tableView, indexPath, itemIdentifier in
			guard let self else { return UITableViewCell() }
			switch itemIdentifier {
			case .setupInstructions:
				return PreferencesGeneralSetupInstructionsCell(
					didTapReadButton: { [weak self] in
						self?.displaySetupInstructions()
					},
					didTapCloseButton: { [weak self] in
						self?.handleSetupInstructionsDimissButtonPressed()
					}
				)
			case .bootstrap:
				return PreferencesGeneralBootstrapCell(
					didTapSelectInstallDiskButton: { [weak self] in
						self?.displayMacOsInstallDiskPicker()
					},
					didTapCompatibilityListButton: { [weak self] in
						guard let self else { return }
						let vc = PreferencesCompatibilityListViewController()
						let navVC = UINavigationController()
						navVC.viewControllers = [vc]

						present(navVC, animated: true)
					}
				)
			case .bootstrapError:
				return PreferencesGeneralErrorCell(
					title: "You need to bootstrap PocketShaver"
				)
			case .disksColumnDescription:
				return PreferencesGeneralDiskColumnsDescriptionCell()
			case .disksEmptyState:
				return PreferencesEmptyStateCell(
					title: "No files found"
				)
			case .disksDisk(let diskEntry):
				let cell = tableView.dequeueReusableCell(withIdentifier: PreferencesGeneralDiskCell.reuseIdentifier, for: indexPath) as! PreferencesGeneralDiskCell
				let disk = model.disk(forFilename: diskEntry.filename)!
				cell.configure(
					disk: disk,
					didSetIsEnabled: { [weak self] filename, isOn in
						guard let self else { return }

						if #unavailable(iOS 16.0) {
							// iOS 15 can't handle code below
							model.setDiskEnabled(filename: filename, isEnabled: isOn)
							reloadData()
							return
						}

						// The following muddle instead of a simple call to reloadData() is to make the
						// cell do a _move_ animation rather than fade when switching the mount toggle.
						let baselineDisk = model.disk(forIndex: 0)
						let baselineDiskEntry = model.diskEntry(for: baselineDisk)
						let baselineDiskIndexPath = dataSource.indexPath(for: .disksDisk(baselineDiskEntry))!
						let baselineDiskRowIndex = baselineDiskIndexPath.row
						let diskSectionIndex = baselineDiskIndexPath.section

						let change = model.setDiskEnabled(filename: filename, isEnabled: isOn)

						let prevIndexPath = IndexPath(row: baselineDiskRowIndex + change.prevIndex, section: diskSectionIndex)
						let newIndexPath = IndexPath(row: baselineDiskRowIndex + change.newIndex, section: diskSectionIndex)

						tableView.performBatchUpdates {
							self.dataSource.tableView(tableView, moveRowAt: prevIndexPath, to: newIndexPath) { [weak self] in
								self?.reloadData(animatingDifferences: false) // To update snapshot
							}
						}
					},
					didSetDiskType: { [weak self] filename, diskType in
						guard let self else { return }

						model.setDiskType(filename: filename, diskType:diskType)
						reloadData()
						UINotificationFeedbackGenerator().notificationOccurred(.success)
					}
				)
				return cell
			case .disksActions:
				return PreferencesGeneralDiskSectionActionsCell(
					hasDskFile: model.hasDskFile,
					didTapCreateDiskButton: { [weak self] in
						self?.displayCreateDiskDialogue()
					},
					didTapReloadDisksButton: { [weak self] in
						self?.reloadFileList()
					},
					didTapImportDiskButton: { [weak self] in
						self?.displayFileImport()
					}
				)
			case .disksError:
				return PreferencesGeneralErrorCell(
					title: "Must select to mount at least one disk file"
				)
			case .audioEnabledToggle:
				return PreferencesEnabledSettingCell(
					title: "Audio enabled",
					isOn: model.audioEnabled
				) { [weak self] newValue in
					self?.model.audioEnabled = newValue
				}
			case .audioInformation:
				return PreferencesInformationCell(
					text: "Sound from other apps is lowered if audio is enabled during emulation. Having trouble getting audio to work? Read the <link>setup guide</link>."
				) { [weak self] in
					self?.displaySetupInstructions()
				}
			case .iPadMouse:
				return PreferencesGeneralIPadMouseCell(
					initialIPadMouseSetting: model.isIPadMouseEnabled
				) { [weak self] newValue in
					guard let self else { return }

					model.isIPadMouseEnabled = newValue
					reloadData()
					segmentedControlFeedbackGenerator.impactOccurred()
				}
			case .twoFingerSteeringInformation:
				return PreferencesInformationCell(
					text: "Two finger steering is an alternative way to control the mouse without obscuring the cursor with your finger. Read the <link>onboarding</link> to get started.",
					upperMargin: .medium,
					separatorHidden: false
				) { [weak self] in
					guard let self else { return }
					let vc = PreferencesTwoFingerSteeringOnboardingViewController()
					let navVC = UINavigationController()
					navVC.viewControllers = [vc]

					present(navVC, animated: true)
				}
			case .twoFingerSteeringEnabledToggle(let secondFingerClickIsEnabled):
				return PreferencesEnabledSettingCell(
					title: "Two finger steering enabled",
					isOn: secondFingerClickIsEnabled
				) { [weak self] isOn in
					guard let self else { return }

					model.setTwoFingerSteering(enabled: isOn)
					reloadData()
				}
			case .twoFingerSteeringSettings(let twoFingerSteeringSettings):
				return PreferencesGeneralTwoFingerSteeringDetailsCell(
					twoFingerSteeringSettings: twoFingerSteeringSettings
				) { [weak self] in
					guard let self else { return }

					let vc = PreferencesTwoFingerSteeringDetailsViewController { [weak self] in
						self?.reloadData()
					}
					let navVC = UINavigationController()
					navVC.viewControllers = [vc]

					present(navVC, animated: true)
				}
			case .rightClick:
				return PreferencesGeneralRightClickCell(
					initialRightClickSetting: model.rightClickSetting
				) { [weak self] newSetting in
					guard let self else { return }

					model.rightClickSetting = newSetting
					segmentedControlFeedbackGenerator.impactOccurred()
				}
			case .rightClickInformation:
				let text: String
				if UIDevice.isIPad {
					text = "If using bluetooth mouse, right click has to explicitly be enabled in iOS settings under General > Trackpad and Mouse > Secondary click.\nRight click can also be performed with a gamepad button."
				} else {
					text = "Right click can be performed with a gamepad button."
				}

				return PreferencesInformationCell(
					text: text
				)
			case .keyboardAutoOffset:
				return PreferencesGeneralKeyboardAutoOffsetCell(initialKeyboardAutoOffsetSetting: model.keyboardAutoOffsetSetting) { [weak self] newSetting in
					guard let self else { return }
					
					model.keyboardAutoOffsetSetting = newSetting
					segmentedControlFeedbackGenerator.impactOccurred()
				}
			case .keyboardAutoOffsetInformation:
				return PreferencesInformationCell(
					text: "Controls how the screen scrolls when you three finger swipe up to present keyboard."
				)
			case .hapticFeedbackSwipeGesturesToggle:
				return PreferencesEnabledSettingCell(
					title: "Two / three finger swipe gestures",
					isOn: model.isGestureHapticFeedbackOn
				) { [weak self] isOn in
					self?.model.isGestureHapticFeedbackOn = isOn
				}
			case .hapticFeedbackMouseClicksToggle:
				return PreferencesEnabledSettingCell(
					title: "Mouse clicks",
					isOn: model.isMouseHapticFeedbackOn
				) { [weak self] isOn in
					self?.model.isMouseHapticFeedbackOn = isOn
				}
			case .hapticFeedbackGamepadKeyStrokesToggle:
				return PreferencesEnabledSettingCell(
					title: "Gamepad key strokes",
					isOn: model.isKeyHapticFeedbackOn
				) { [weak self] isOn in
					self?.model.isKeyHapticFeedbackOn = isOn
				}
			case .hintsToggle:
				return PreferencesEnabledSettingCell(
					title: "Show hints",
					isOn: model.showHints
				) { [weak self] newValue in
					self?.model.showHints = newValue
				}
			case .hintsInformation:
				return PreferencesInformationCell(
					text: "Gamepad layout names are shown even when hints are turned off."
				)
			}
		}

		dataSource.sectionTitleProvider = { section in
			switch section {
			case .setupInstructions:
				return nil
			case .bootstrap:
				return "Bootstrap"
			case .disks:
				return "Disks"
			case .audio:
				return "Audio"
			case .iPadMouse:
				return "Input mode"
			case .twoFingerSteering:
				return "Two finger steering"
			case .rightClick:
				return "Right click"
			case .keyboardAutoOffset:
				return "Software keyboard screen offset"
			case .hapticFeedback:
				return "Haptic feedback"
			case .hints:
				return "Hints"
			}
		}

		dataSource.canEditProvider = { [weak self] identifier in
			guard let self,
				  case .disksDisk(let diskEntry) = identifier else {
				return false
			}

			let disk = model.disk(forFilename: diskEntry.filename)!

			return !disk.isEnabled
		}

		dataSource.commitEditProvider = { [weak self] identifier, editingStyle in
			guard let self,
				  case .disksDisk(let diskEntry) = identifier,
				  editingStyle == .delete else {
				return
			}

			let disk = model.disk(forFilename: diskEntry.filename)!
			model.deleteDisk(disk)

			reloadData()
		}

		dataSource.defaultRowAnimation = .fade
		tableView.dataSource = dataSource

		reloadData()
	}

	private func reloadData(
		animatingDifferences: Bool = true,
		completion: (() -> Void)? = nil
	) {
		var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()

		if !model.hasDismissedSetupInstructions {
			snapshot.appendSections([.setupInstructions])
			snapshot.appendItems([.setupInstructions])
		}

		if !model.hasRomFile {
			snapshot.appendSections([.bootstrap])
			snapshot.appendItems([.bootstrap])
			if model.isDisplayingRomFileMissingError {
				snapshot.appendItems([.bootstrapError])
			}
		}

		snapshot.appendSections([.disks])
		snapshot.appendItems([.disksColumnDescription])
		if model.numberOfDisks == 0 {
			snapshot.appendItems([.disksEmptyState])
		} else {
			for diskIndex in 0..<model.numberOfDisks {
				let disk = model.disk(forIndex: diskIndex)
				let diskEntry = PreferencesGeneralModel.DiskEntry(
					index: diskIndex,
					filename: disk.filename,
					type: disk.type
				)
				snapshot.appendItems([.disksDisk(diskEntry)])
			}
		}
		snapshot.appendItems([.disksActions])
		if model.isDisplayingNoDiskFilesError {
			snapshot.appendItems([.disksError])
		}

		snapshot.appendSections([.audio])
		snapshot.appendItems([
			.audioEnabledToggle,
			.audioInformation
		])

		if UIDevice.isIPad {
			snapshot.appendSections([.iPadMouse])
			snapshot.appendItems([.iPadMouse])
		}

		if !model.isIPadMouseEnabled {
			snapshot.appendSections([.twoFingerSteering])
			snapshot.appendItems([
				.twoFingerSteeringInformation,
				.twoFingerSteeringEnabledToggle(model.twoFingerSteeringSettings.secondFingerClick)
			])
			if model.twoFingerSteeringSettings.secondFingerClick {
				snapshot.appendItems([
					.twoFingerSteeringSettings(model.twoFingerSteeringSettings)
				])
			}
		}

		snapshot.appendSections([.rightClick])
		snapshot.appendItems([
			.rightClick,
			.rightClickInformation
		])

		snapshot.appendSections([.keyboardAutoOffset])
		snapshot.appendItems([
			.keyboardAutoOffset,
			.keyboardAutoOffsetInformation
		])

		if model.supportsHaptics {
			snapshot.appendSections([.hapticFeedback])
			snapshot.appendItems([
				.hapticFeedbackSwipeGesturesToggle,
				.hapticFeedbackMouseClicksToggle,
				.hapticFeedbackGamepadKeyStrokesToggle
			])
		}
		snapshot.appendSections([.hints])
		snapshot.appendItems([
			.hintsToggle,
			.hintsInformation
		])

		dataSource.apply(
			snapshot,
			animatingDifferences: animatingDifferences,
			completion: completion
		)
	}

	func reloadSection(_ section: Section) {
		var snapshot = dataSource.snapshot()
		snapshot.reloadSections([section])
		dataSource.apply(snapshot)
	}

	func presentRomFileMissingError() {
		let bootstrapCellIndexPath = dataSource.indexPath(for: .bootstrap)!

		model.isDisplayingRomFileMissingError = true

		tableView.scrollToRow(at: bootstrapCellIndexPath, at: .top, animated: true)

		reloadData()
	}

	func presentNoDiskFilesError() {
		let disksActionsIndexPath = dataSource.indexPath(for: .disksActions)!

		model.isDisplayingNoDiskFilesError = true

		tableView.scrollToRow(at: disksActionsIndexPath, at: .middle, animated: true)

		reloadData()
	}

	private func displaySetupInstructions() {
		let vc = PreferencesSetupInstructionsViewController()
		let navVC = UINavigationController()
		navVC.viewControllers = [vc]

		present(navVC, animated: true)
	}

	// MARK: - Bootstrapping

	private func displayMacOsInstallDiskPicker() {
		let pickerVC = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
		pickerVC.delegate = self
		pickerVC.view.tag = FilePickerSource.romSelection.rawValue

		present(pickerVC, animated: true)
	}

	private func animateRomFound() {
		guard let cell = tableView.visibleCells.first(where: { $0 is PreferencesGeneralBootstrapCell }) as? PreferencesGeneralBootstrapCell else {
			return
		}

		cell.displayCheckmark()

		DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
			self?.reloadData()
		}
	}

	private func displayNoRomFoundDialogue() {
		let alertVC = UIAlertController(
			title: "Mac OS install disc image not compatible",
			message: "The provided file is not a compatible Mac OS install disc image for bootstrapping PocketShaver. Check 'Compatibility list' for guidence.",
			preferredStyle: .alert
		)

		alertVC.addAction(.init(title: "Ok", style: .default))

		present(alertVC, animated: true)
	}

	private func displayIncompatibleRomFoundDialogue(_ romType: NewWorldRomVersion) {
		let alertVC = UIAlertController(
			title: "Mac OS install disc image not compatible",
			message: "The provided file is a Mac OS disk install image, but is not compatible for bootstrapping PocketShaver. The file is identified as belonging to category '\(romType.description)'. Check 'Compatibility list' for guidence.",
			preferredStyle: .alert
		)

		alertVC.addAction(.init(title: "Ok", style: .default))

		present(alertVC, animated: true)
	}

	// MARK: - Create disk

	private func displayCreateDiskDialogue() {
		let alertVC = createDiskDialogueFactory.create { [weak self] specification in
			guard let self else { return }

			do {
				let newDisk = try model.createNewDisk(
					name: specification.name,
					sizeInMb: specification.size
				)
				reloadData { [weak self] in
					guard let self,
						  let newDisk else {
						return
					}

					scrollToDiskIfNotVisible(newDisk)
				}
			} catch PreferencesGeneralError.fileCreationInvalidSize {
				let invalidSizeAlertVC = UIAlertController.withMessage("An invalid file size was given")
				present(invalidSizeAlertVC, animated: true)
			} catch PreferencesGeneralError.fileWithFilenameAleadyExists {
				let fileExistsAlertVC = UIAlertController.withMessage("A file with that name already exists")
				present(fileExistsAlertVC, animated: true)
			} catch {
				let otherErrorAlertVC = UIAlertController.withMessage("Something went wrong when trying to create the file")
				present(otherErrorAlertVC, animated: true)
			}
		}

		present(alertVC, animated: true)
	}

	private func reloadFileList() {
		Task { [weak self] in
			guard let self else { return }
			try await model.didSelectReload()
			reloadData()
		}
	}

	// MARK: - File import

	private func displayFileImport() {
		let pickerVC = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
		pickerVC.delegate = self
		pickerVC.view.tag = FilePickerSource.fileImport.rawValue

		present(pickerVC, animated: true)
	}

	private func handleSetupInstructionsDimissButtonPressed() {
		if InformationConsumption.current.hasReadSetupInstructions {
			let alertVC = UIAlertController(
				title: "Information",
				message: "Setup instructions will still be accessible from the bottom of Advanced tab.",
				preferredStyle: .alert
			)

			alertVC.addAction(.init(title: "Ok", style: .default, handler: { [weak self] _ in
				guard let self else { return }
				model.reportHasDismissedSetupInstructions()
				reloadData()
			}))

			present(alertVC, animated: true)
		} else {
			let alertVC = UIAlertController(
				title: "Warning",
				message: "Step 5 & 8 of setup instructions are non-trivial and must be follwed for succesful setup.\nIf setup instructions is dismissed from here, it can still be accessed from the bottom of Advanced tab.",
				preferredStyle: .alert
			)

			alertVC.addAction(.init(title: "Dismiss", style: .default, handler: { [weak self] _ in
				guard let self else { return }
				model.reportHasDismissedSetupInstructions()
				reloadData()
			}))

			alertVC.addAction(.init(title: "Cancel", style: .cancel))

			present(alertVC, animated: true)
		}
	}

	private func scrollToDiskIfNotVisible(_ disk: Disk) {
		let diskEntry = model.diskEntry(for: disk)
		guard let cellIndexPath = dataSource.indexPath(for: .disksDisk(diskEntry)) else { return }

		let cell = dataSource.tableView(tableView, cellForRowAt: cellIndexPath)
		if !tableView.visibleCells.contains(cell) {
			tableView.scrollToRow(at: cellIndexPath, at: .middle, animated: true)
		}
	}

	// MARK: - Actions

	@objc
	private func appDidResume() {
		Task { @MainActor [weak self] in
			self?.reloadFileList()
		}
	}
}

// MARK: - UITableViewDelegate

extension PreferencesGeneralViewController {
	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		false
	}
}

// MARK: - UIDocumentPickerDelegate

extension PreferencesGeneralViewController: UIDocumentPickerDelegate {
	func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
		guard let url = urls.first else {
			return
		}

		switch FilePickerSource(rawValue: controller.view.tag)! {
		case .romSelection:
			Task { [weak self, model] in
				guard let self else { return }
				let validationResult = await model.didSelectMacOsInstallDiskCandidate(url: url)
				switch validationResult {
				case .success:
					animateRomFound()
				case .incompatibleRom(let newWorldRomVersion):
					displayIncompatibleRomFoundDialogue(newWorldRomVersion)
				case .invalidFile:
					displayNoRomFoundDialogue()
				case .error(let error):
					let errorVC = UIAlertController.withError(error)
					present(errorVC, animated: true)
				}
			}
		case .fileImport:
			Task { [weak self, model] in
				guard let self else { return }
				do {
					let newDisk = try await model.didSelectFileImport(url: url)
					reloadData { [weak self] in
						guard let self,
							  let newDisk else {
							return
						}

						scrollToDiskIfNotVisible(newDisk)
					}
				} catch PreferencesGeneralError.fileImportWrongSuffix {
					let supportedFormatsString = DiskManager.supportedFileExtensions.map({ ".\($0)" }).joined(separator: ", ")
					let wrongSuffixAlertVC = UIAlertController.withMessage("The file has an unsupported suffix. The supported suffixes are \(supportedFormatsString).")
					present(wrongSuffixAlertVC, animated: true)
				} catch PreferencesGeneralError.fileWithFilenameAleadyExists {
					let fileExistsAlertVC = UIAlertController.withMessage("A file with that name already exists")
					present(fileExistsAlertVC, animated: true)
				} catch {
					let errorVC = UIAlertController.withError(error)
					present(errorVC, animated: true)
				}
			}
		}
	}
}
