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
		case welcome
		case disks
		case gamepadOverlays
		case iPadMouse
		case twoFingerSteering
		case rightClick
		case keyboardAutoOffset
		case audio
		case hints
	}

	enum Row: Hashable {
		// setupInstructions
		case setupInstructions

		// bootstrap
		case bootstrap
		case bootstrapError

		// welcome
		case welcome

		// disks
		case diskActionBar
		case disksEmptyState
		case disksDisk(PreferencesGeneralModel.DiskEntry)
		case disksError

		// gamepadOverlays
		case gamepadOverlays

		// iPadMouse
		case iPadMouse

		// twoFingerSteering
		case twoFingerSteeringInformation
		case twoFingerSteeringEnabledToggle(Bool)
		case twoFingerSteeringSettings(TwoFingerSteeringSetting)

		// rightClick
		case rightClick
		case rightClickInformation

		// keyboardAutoOffset
		case keyboardAutoOffset
		case keyboardAutoOffsetInformation

		// audio
		case audioEnabledToggle
		case audioInformation

		// hints
		case hintsToggle
		case hintsInformation
	}

	enum FilePickerSource: Int {
		case romSelection
		case fileImport
	}

	private let model: PreferencesGeneralModel
	private var anyCancellables = Set<AnyCancellable>()
	private let createDiskDialogueFactory = PreferencesGeneralCreateDiskDialogueFactory()

	private var dataSource: TableViewDiffableDataSource<Section, Row>!

	private let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

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
		model.changeSubject.sink { [weak self] change in
			guard let self else { return }
			switch change {
			case .gamepadLayoutsDidUpdate:
				dataSource.reloadSection(.gamepadOverlays)
			default: break
			}

		}.store(in: &anyCancellables)

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
					},
					didTapDoneButton: { [weak self] in
						guard let self else { return }

						model.shouldDisplayBootstrapSection = false
						reloadData()
					}
				)
			case .bootstrapError:
				return PreferencesGeneralErrorCell(
					title: "You need to bootstrap PocketShaver"
				)
			case .welcome:
				return PreferencesGeneralWelcomeCell()
			case .diskActionBar:
				return PreferencesGeneralDiskActionBarCell(
					didTapOpenShareFolderButton: { [weak self] in
						self?.openDocumentsFolder()
					},
					didTapReloadButton: { [weak self] in
						self?.reloadFileList()

						UINotificationFeedbackGenerator().notificationOccurred(.success)
					},
					didTapCreateAction: { [weak self] in
						self?.displayCreateDiskDialogue()
					},
					didTapImportAction: { [weak self] in
						self?.displayFileImport()
					}
				)
			case .disksEmptyState:
				let subtitles: [(String, StringTagConfig)]
				switch UIDevice.deviceType {
				case .iPhone,
						.iPad:
					subtitles = [
						(
							"Tap <img/> to create or import a disk file",
							.init(
								images: [
									Assets.plus.asSymbolImage()
								]
							)
						),
						(
							"Alternatively, add a file manually to PocketShaver share folder and tap <img/>",
							.init(
								images: [
									ImageResource.arrowTriangleheadCounterclockwiseRotate90.asSymbolImage()
								]
							)
						)
					]
				case .mac:
					subtitles = [
						(
							"Click <img/> to create or import a disk file",
							.init(
								images: [
									Assets.plus.asSymbolImage()
								]
							)
						),
						(
							"Alternatively, add a file manually to PocketShaver share folder and click <img/>",
							.init(
								images: [
									ImageResource.arrowTriangleheadCounterclockwiseRotate90.asSymbolImage()
								]
							)
						),
						(
							"Click <img/> to open the share folder in Finder",
							.init(
								images: [
									Assets.folder
								]
							)
						)
					]
				}

				return PreferencesEmptyStateCell(
					title: "No disk files found",
					subtitles: subtitles
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
			case .disksError:
				return PreferencesGeneralErrorCell(
					title: "Must select to mount at least one disk file"
				)
			case .gamepadOverlays:
				return PreferencesGeneralGamepadOverlaysCell(
					containerVC: self,
					gamepadConfigs: model.gamepadConfigs
				) { [weak self] in
						guard let self else { return }
						let vc = PreferencesGamepadManageViewController(changeSubject: model.changeSubject)
						let navVC = UINavigationController()
						navVC.viewControllers = [vc]

						present(navVC, animated: true)
					}
			case .iPadMouse:
				return PreferencesGeneralIPadMouseCell(
					initialIPadMouseSetting: model.isIPadMouseEnabled
				) { [weak self] newValue in
					guard let self else { return }

					model.isIPadMouseEnabled = newValue
					reloadData()
					feedbackGenerator.impactOccurred()
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

					model.twoFingerSteeringSetting = isOn ? .clickPlusSwipePlusBootInHoverMode : .off
					reloadData()
				}
			case .twoFingerSteeringSettings(let twoFingerSteeringSetting):
				return PreferencesGeneralTwoFingerSteeringDetailsCell(
					twoFingerSteeringSetting: twoFingerSteeringSetting
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
					feedbackGenerator.impactOccurred()
				}
			case .rightClickInformation:
				let text: String
				if UIDevice.deviceType == .iPad {
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
					feedbackGenerator.impactOccurred()
				}
			case .keyboardAutoOffsetInformation:
				return PreferencesInformationCell(
					text: "Controls how the screen scrolls when you three finger swipe up to present keyboard."
				)
			case .audioEnabledToggle:
				return PreferencesEnabledSettingCell(
					title: "Audio enabled",
					isOn: model.audioEnabled
				) { [weak self] newValue in
					self?.model.audioEnabled = newValue
				}
			case .audioInformation:
				var soundFromOtherAppsPrefix = ""
				if UIDevice.deviceType != .mac {
					soundFromOtherAppsPrefix = "Sound from other apps is lowered if audio is enabled during emulation. "
				}
				return PreferencesInformationCell(
					text: "\(soundFromOtherAppsPrefix)Having trouble getting audio to work? Read the <link>setup guide</link>."
				) { [weak self] in
					self?.displaySetupInstructions()
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
					text: "Gamepad overlay names are shown even when hints are turned off."
				)
			}
		}

		dataSource.sectionTitleProvider = { section in
			switch section {
			case .setupInstructions:
				return nil
			case .bootstrap:
				return nil
			case .welcome:
				return nil
			case .disks:
				return UIDevice.deviceType == .iPad ? "Disks" : nil
			case .gamepadOverlays:
				return "Gamepad overlays"
			case .iPadMouse:
				return "Input mode"
			case .twoFingerSteering:
				return "Two finger steering"
			case .rightClick:
				return "Right click"
			case .keyboardAutoOffset:
				return "Software keyboard screen offset"
			case .audio:
				return "Audio"
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

		if model.shouldDisplayBootstrapSection {
			snapshot.appendSections([.bootstrap])
			snapshot.appendItems([.bootstrap])
			if model.isDisplayingRomFileMissingError {
				snapshot.appendItems([.bootstrapError])
			}
		} else if UIDevice.deviceType == .mac,
		   model.mode == .startup {
			snapshot.appendSections([.welcome])
			snapshot.appendItems([.welcome])
		}

		snapshot.appendSections([.disks])
		snapshot.appendItems([.diskActionBar])
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

		if model.isDisplayingNoDiskFilesError {
			snapshot.appendItems([.disksError])
		}

		if UIDevice.deviceType != .mac {
			snapshot.appendSections([.gamepadOverlays])
			snapshot.appendItems([.gamepadOverlays])

			if UIDevice.deviceType == .iPad {
				snapshot.appendSections([.iPadMouse])
				snapshot.appendItems([.iPadMouse])
			}

			if !model.isIPadMouseEnabled {
				let isTwoFingerSteeringEnabled = model.twoFingerSteeringSetting != .off
				snapshot.appendSections([.twoFingerSteering])
				snapshot.appendItems([
					.twoFingerSteeringInformation,
					.twoFingerSteeringEnabledToggle(isTwoFingerSteeringEnabled)
				])
				if isTwoFingerSteeringEnabled {
					snapshot.appendItems([
						.twoFingerSteeringSettings(model.twoFingerSteeringSetting)
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
		}

		snapshot.appendSections([.audio])
		snapshot.appendItems([
			.audioEnabledToggle,
			.audioInformation
		])

		if UIDevice.deviceType != .mac {
			snapshot.appendSections([.hints])
			snapshot.appendItems([.hintsToggle])
			if UIDevice.deviceType != .mac {
				snapshot.appendItems([.hintsInformation])
			}
		}

		dataSource.apply(
			snapshot,
			animatingDifferences: animatingDifferences,
			completion: completion
		)
	}

	func presentRomFileMissingError() {
		let bootstrapCellIndexPath = dataSource.indexPath(for: .bootstrap)!

		model.isDisplayingRomFileMissingError = true

		tableView.scrollToRow(at: bootstrapCellIndexPath, at: .top, animated: true)

		reloadData()
	}

	func presentNoDiskFilesError() {
		let sectionAfterDiskIndex = dataSource.snapshot().indexOfSection(.disks)! + 1
		let afterDiskIndexPath = IndexPath(row: 0, section: sectionAfterDiskIndex)

		model.isDisplayingNoDiskFilesError = true

		tableView.scrollToRow(at: afterDiskIndexPath, at: .bottom, animated: true)

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

	private func animateBootstrapCompleted() {
		guard let cell = tableView.visibleCells.first(where: { $0 is PreferencesGeneralBootstrapCell }) as? PreferencesGeneralBootstrapCell else {
			return
		}

		cell.displayBootstrapCompleted()
		tableView.beginUpdates()
		tableView.endUpdates()
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
		let alertVC: UIAlertController
		if romType.isInstallCompatible {
			alertVC = UIAlertController(
				title: "Almost.. but cannot bootrap with this file",
				message: "PocketShaver can run this OS version, and you can use this disc for installing Mac OS onto a disk drive later. But the disc file cannot be used for bootstrapping.\nThe file is identified as belonging to category '\(romType.description)'. Check 'Bootstrap compatibility list' for guidence.",
				preferredStyle: .alert
			)
		} else {
			alertVC = UIAlertController(
				title: "Not compatible",
				message: "The provided file is a Mac OS disc install image, but not compatible with PocketShaver. The file is identified as belonging to category '\(romType.description)'. Check 'Bootstrap compatibility list' for guidence.",
				preferredStyle: .alert
			)
		}

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

	// MARK: - Open documents folder

	private func openDocumentsFolder() {
		// Only works on mac. And is only needed there, too.
		UIApplication.shared.open(FileManager.documentUrl)
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
					animateBootstrapCompleted()
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
