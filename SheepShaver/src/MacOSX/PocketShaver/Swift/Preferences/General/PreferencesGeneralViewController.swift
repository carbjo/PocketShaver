//
//  PreferencesGeneralViewController.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

import UIKit
import Combine

class PreferencesGeneralViewController: UITableViewController {
	enum SectionType: Int, CaseIterable {
		case setupInstructions
		case bootstrap
		case disks
		case audio
		case iPadMouse
		case secondFinger
		case rightClick
		case hapticFeedback
		case hints
	}

	enum CreateDiskFieldIndex: Int {
		case name
		case size
	}

	enum FilePickerSource: Int {
		case romSelection
		case fileImport
	}

	private let model: PreferencesGeneralModel

	private var createDiskDialogueNamePhantomLabel: UILabel?
	private var createDiskDialogueNameSuffixLabel: UILabel?
	private var createDiskDialogueSizePhantomLabel: UILabel?
	private var createDiskDialogueSizeUnitLabel: UILabel?

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

		NotificationCenter.default.addObserver(self, selector: #selector(updateRomPickerSection), name: UIApplication.didBecomeActiveNotification, object: nil)
	}

	func presentRomFileMissingError() {
		let sectionIndex = SectionType.bootstrap.sectionIndex(model: model)
		let romCellIndexPath = IndexPath(row: 0, section: sectionIndex)

		let shouldAddRow = !model.isDisplayingRomFileMissingError

		model.isDisplayingRomFileMissingError = true

		let romErrorCellIndexPath = IndexPath(row: 1, section: sectionIndex)

		tableView.performBatchUpdates {
			tableView.scrollToRow(at: romCellIndexPath, at: .top, animated: true)
			if shouldAddRow {
				tableView.insertRows(at: [romErrorCellIndexPath], with: .fade)
			}
		}
	}

	func presentNoDiskFilesError() {
		let sectionIndex = SectionType.disks.sectionIndex(model: model)
		let diskCellsIndexPath = IndexPath(row: 0, section: sectionIndex)

		let shouldAddRow = !model.isDisplayingNoDiskFilesError

		model.isDisplayingNoDiskFilesError = true

		tableView.performBatchUpdates {
			tableView.scrollToRow(at: diskCellsIndexPath, at: .top, animated: true)
			if shouldAddRow {
				let disksMissingErrorIndexPath = IndexPath(row: 2, section: sectionIndex)
				tableView.insertRows(at: [disksMissingErrorIndexPath], with: .fade)
			}
		}
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
		guard let cell = tableView.visibleCells.first(where: { $0 is PreferencesGeneralBootstrapCell }) as? PreferencesGeneralBootstrapCell,
		let indexPath = tableView.indexPath(for: cell) else {
			return
		}

		cell.displayCheckmark()

		DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
			self.tableView.deleteSections(IndexSet([indexPath.section]), with: .fade)
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
		let alertVC = UIAlertController(
			title: "Create new disk",
			message: "Choose name and size",
			preferredStyle: .alert
		)
		alertVC.addTextField { [weak self] textField in
			guard let self else { return }

			textField.tag = CreateDiskFieldIndex.name.rawValue
			textField.placeholder = "DiskName.dsk"
			textField.autocapitalizationType = .sentences

			let phantomLabel = UILabel.withoutConstraints()
			phantomLabel.font = textField.font
			phantomLabel.isHidden = true

			let suffixLabel = UILabel.withoutConstraints()
			suffixLabel.font = textField.font
			suffixLabel.text = ".dsk"
			suffixLabel.isHidden = true

			textField.addSubview(phantomLabel)
			textField.addSubview(suffixLabel)

			NSLayoutConstraint.activate([
				phantomLabel.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
				phantomLabel.centerYAnchor.constraint(equalTo: textField.centerYAnchor),

				suffixLabel.leadingAnchor.constraint(equalTo: phantomLabel.trailingAnchor),
				suffixLabel.centerYAnchor.constraint(equalTo: textField.centerYAnchor)
			])

			textField.delegate = self

			self.createDiskDialogueNamePhantomLabel = phantomLabel
			self.createDiskDialogueNameSuffixLabel = suffixLabel
		}

		alertVC.addTextField { [weak self] textField in
			guard let self else { return }

			textField.tag = CreateDiskFieldIndex.size.rawValue
			textField.placeholder = "0"
			textField.keyboardType = .numberPad

			let phantomLabel = UILabel.withoutConstraints()
			phantomLabel.text = "0"
			phantomLabel.font = textField.font
			phantomLabel.isHidden = true

			let unitLabel = UILabel.withoutConstraints()
			unitLabel.text = "MB"
			unitLabel.font = textField.font
			unitLabel.textColor = .gray

			textField.addSubview(phantomLabel)
			textField.addSubview(unitLabel)

			NSLayoutConstraint.activate([
				phantomLabel.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
				phantomLabel.centerYAnchor.constraint(equalTo: textField.centerYAnchor),

				unitLabel.leadingAnchor.constraint(equalTo: phantomLabel.trailingAnchor, constant: 4),
				unitLabel.centerYAnchor.constraint(equalTo: textField.centerYAnchor)
			])

			textField.delegate = self

			self.createDiskDialogueSizePhantomLabel = phantomLabel
			self.createDiskDialogueSizeUnitLabel = unitLabel
		}

		alertVC.addAction(.init(title: "Cancel", style: .cancel, handler: { [weak self] _ in
			guard let self else { return }

			createDiskDialogueNamePhantomLabel = nil
			createDiskDialogueNameSuffixLabel = nil
		}))
		alertVC.addAction(.init(title: "Create", style: .default, handler: { [weak self] action in
			guard let self else { return }

			createDiskDialogueNamePhantomLabel = nil
			createDiskDialogueNameSuffixLabel = nil

			let name = alertVC.textFields?[0].text ?? ""
			let sizeString = alertVC.textFields?[1].text ?? ""
			let size = Int(sizeString) ?? 0
			do {
				let diskDataChange = try model.createNewDisk(name: name, sizeInMb: size)
				animateDiskDataChange(diskDataChange)
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
		}))

		present(alertVC, animated: true)
	}

	private func animateDiskDataChange(_ diskDataChange: DiskDataChange) {
		let sectionIndex = SectionType.disks.sectionIndex(model: model)

		let startsDisplayingEmptyState = model.numberOfDisks == 0
		let stopsDisplayingEmptyState = model.numberOfDisks == diskDataChange.inserted.count

		tableView.performBatchUpdates {
			if startsDisplayingEmptyState || stopsDisplayingEmptyState {
				// Replace the empty state cell
				let columnsDescriptionIndexPath = IndexPath(row: 0, section: sectionIndex)
				tableView.reloadRows(at: [columnsDescriptionIndexPath], with: .fade)
			}

			tableView.insertRows(at: diskDataChange.inserted.map({ IndexPath(row: 1 + $0, section: sectionIndex) }), with: .fade)
			tableView.reloadRows(at: diskDataChange.updated.map({ IndexPath(row: 1 + $0, section: sectionIndex) }), with: .fade)
			tableView.deleteRows(at: diskDataChange.removed.map({ IndexPath(row: 1 + $0, section: sectionIndex) }), with: .fade)
		}

		let diskActionsRowIndex = model.numberOfDisks + 1
		let diskActionsIndexPath = IndexPath(row: diskActionsRowIndex, section: sectionIndex)
		if let cell = tableView.cellForRow(at: diskActionsIndexPath) as? PreferencesGeneralDiskSectionActionsCell {
			cell.setupForHasDskFile(model.hasDskFile, animated: true)
		}
 	}

	private func reloadFileList() {
		Task { [weak self] in
			guard let self else { return }
			let diskDataChange = try await model.didSelectReload()
			animateDiskDataChange(diskDataChange)
		}
	}

	// MARK: - File import

	private func displayFileImport() {
		let pickerVC = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
		pickerVC.delegate = self
		pickerVC.view.tag = FilePickerSource.fileImport.rawValue

		present(pickerVC, animated: true)
	}

	// MARK: - Actions

	@objc
	private func updateRomPickerSection() {
		let isDisplayingRomPicker = tableView.visibleCells.contains(where: { $0 is PreferencesGeneralBootstrapCell })
		if model.hasRomFile && isDisplayingRomPicker {
			animateRomFound()
		} else if !model.hasRomFile && !isDisplayingRomPicker {
			let romSection = SectionType.bootstrap.sectionIndex(model: model)
			tableView.insertSections([romSection], with: .top)
		}
	}
}

// MARK: - UITextFieldDelegate

extension PreferencesGeneralViewController: UITextFieldDelegate {
	func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
		let currentString = (textField.text ?? "") as NSString
		let newString = currentString.replacingCharacters(in: range, with: string)

		switch CreateDiskFieldIndex(rawValue: textField.tag)! {
		case .name:
			createDiskDialogueNamePhantomLabel?.text = newString
			createDiskDialogueNameSuffixLabel?.isHidden = newString.isEmpty
		case .size:
			createDiskDialogueSizePhantomLabel?.text = newString.isEmpty ? "0" : newString
		}

		return true
	}
}

// MARK: - UITableViewDataSource

extension PreferencesGeneralViewController {
	override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
		let sectionType = SectionType(sectionIndex: section, model: model)
		switch sectionType {
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
		case .secondFinger:
			return "Second finger"
		case .rightClick:
			return "Right click"
		case .hapticFeedback:
			return "Haptic feedback"
		case .hints:
			return "Hints"
		}
	}

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		let sectionType = SectionType(sectionIndex: section, model: model)
		switch sectionType {
		case .setupInstructions:
			return 1
		case .bootstrap:
			return 1 + (model.isDisplayingRomFileMissingError ? 1 : 0)
		case .disks:
			return model.numberOfDisks + 2 + (model.isDisplayingNoDiskFilesError ? 1 : 0)
		case .audio:
			return 2
		case .iPadMouse:
			return 1
		case .secondFinger:
			if model.secondFingerSwipe {
				return 6
			} else if model.secondFingerClick {
				return 4
			}
			return 2
		case .rightClick:
			return 2
		case .hapticFeedback:
			return 3
		case .hints:
			return 2
		}
	}
	
	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let sectionType = SectionType(sectionIndex: indexPath.section, model: model)
		switch sectionType {
		case .setupInstructions:
			return PreferencesGeneralSetupInstructionsCell(
				didTapReadButton: { [weak self] in
					guard let self else { return }
					displaySetupInstructions()
				},
				didTapCloseButton: { [weak self] in
					guard let self else { return }
					let setupInstructionsSectionIndexBeforeChange = SectionType.setupInstructions.sectionIndex(model: model)
					model.reportHasDismissedSetupInstructions()
					tableView.deleteSections(IndexSet([setupInstructionsSectionIndexBeforeChange]), with: .fade)
				}
			)
		case .bootstrap:
			if indexPath.row == 0 {
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
			} else {
				return PreferencesGeneralErrorCell(title: "You need to bootstrap PocketShaver")
			}
		case .disks:
			if indexPath.row == 0, model.numberOfDisks == 0 {
				return PreferencesGeneralDiskEmptyStateCell()
			} else if indexPath.row == 0 {
				return PreferencesGeneralDiskColumnsDescriptionCell()
			} else if indexPath.row <= model.numberOfDisks {
				let index = indexPath.row - 1
				let disk = model.disk(forIndex: index)
				return PreferencesGeneralDiskCell(
					disk: disk,
					didSetIsEnabled: { [weak self] filename, isOn in
						self?.model.setDiskEnabled(filename: filename, isEnabled: isOn)
					},
					didSetIsCdRom: { [weak self] filename, isOn in
						self?.model.setDiskAsCdRom(filename: filename, isCdRom: isOn)
					}
				)
			} else if indexPath.row == model.numberOfDisks + 1 {
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
			} else {
				return PreferencesGeneralErrorCell(title: "Must select to mount at least one disk file")
			}
		case .audio:
			if indexPath.row == 0 {
				return PreferencesEnabledSettingCell(
					title: "Audio enabled",
					isOn: !model.soundDisabled
				) { [weak self] newValue in
					self?.model.soundDisabled = !newValue
				}
			} else {
				return PreferencesGeneralAudioFooterCell { [weak self] in
					self?.displaySetupInstructions()
				}
			}
		case .iPadMouse:
			return PreferencesGeneralIPadMouseCell(
				initialIPadMouseSetting: model.isIPadMouseEnabled
			) { [weak self] newValue in
				self?.model.isIPadMouseEnabled = newValue
			}
		case .secondFinger:
			switch indexPath.row {
			case 0:
				return PreferencesEnabledSettingCell(
					title: "Second finger click",
					isOn: model.secondFingerClick
				) { [weak self] isOn in
					self?.set(secondFingerClick: isOn)
				}
			case 1:
				return PreferencesFooterCell(
					text: "A second finger can be used for mouse clicking (while the first finger moves the position). Only has effect when either relative mouse mode or any of the hover modes are enabled.",
					separatorHidden: !model.secondFingerClick
				)
			case 2:
				return PreferencesEnabledSettingCell(
					title: "Second finger swipe",
					isOn: model.secondFingerSwipe
				) { [weak self] isOn in
					self?.set(secondFingerSwipe: isOn)
				}
			case 3:
				return PreferencesFooterCell(
					text: "A second finger can be used for quickly swiping between mouse offset modes. Only has effect when any of the hover modes are enabled. Can be used to switch between no offset / offset above / offset to the side / offset diagnoally above.",
					separatorHidden: !model.secondFingerSwipe
				)
			case 4:
				return PreferencesEnabledSettingCell(
					title: "Boot in hover mode",
					isOn: model.bootInHoverMode
				) { [weak self] isOn in
					self?.set(bootInHoverMode: isOn)
				}
			case 5:
				return PreferencesFooterCell(
					text: "Hover mode (without offset) is on by default when booting, making second finger swipe available from the start."
				)
			default: fatalError()
			}
		case .rightClick:
			switch indexPath.row {
			case 0:
				return PreferencesGeneralRightClickCell(initialRightClickSetting: model.rightClickSetting) { [weak self] newSetting in
					self?.model.rightClickSetting = newSetting
				}
			case 1:
				let text: String
				if UIDevice.isIPad {
					text = "If using bluetooth mouse, right click has to explicitly be enabled in iOS settings under General > Trackpad and Mouse > Secondary click.\nRight click can also be performed with a gamepad button."
				} else {
					text = "Right click can be performed with a gamepad button."
				}

				return PreferencesFooterCell(
					text: text
				)
			default:
				fatalError()
			}
		case .hapticFeedback:
			switch indexPath.row {
			case 0:
				return PreferencesEnabledSettingCell(
					title: "Three / two finger swipe gestures",
					isOn: model.isGestureHapticFeedbackOn
				) { [weak self] isOn in
					self?.model.isGestureHapticFeedbackOn = isOn
				}
			case 1:
				return PreferencesEnabledSettingCell(
					title: "Mouse clicks",
					isOn: model.isMouseHapticFeedbackOn
				) { [weak self] isOn in
					self?.model.isMouseHapticFeedbackOn = isOn
				}
			case 2:
				return PreferencesEnabledSettingCell(
					title: "Gamepad key strokes",
					isOn: model.isKeyHapticFeedbackOn
				) { [weak self] isOn in
					self?.model.isKeyHapticFeedbackOn = isOn
				}
			default:
				fatalError()
			}
		case .hints:
			if indexPath.row == 0 {
				return PreferencesEnabledSettingCell(
					title: "Show hints",
					isOn: model.showHints
				) { [weak self] newValue in
					self?.model.showHints = newValue
				}
			} else {
				return PreferencesFooterCell(
					text: "Gamepad layout names are shown even when hints are turned off."
				)
			}
		}
	}

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		false
	}

	override func numberOfSections(in tableView: UITableView) -> Int {
		let res = SectionType.count(model: model)
		return res
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
					let diskDataChange = try await model.didSelectFileImport(url: url)
					animateDiskDataChange(diskDataChange)
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

extension PreferencesGeneralViewController.SectionType {
	@MainActor
	init(sectionIndex: Int, model: PreferencesGeneralModel) {
		let sections = Self.availableSections(with: model)
		self = sections[sectionIndex]
	}

	@MainActor
	static func count(model: PreferencesGeneralModel) -> Int {
		let sections = Self.availableSections(with: model)
		return sections.count
	}

	@MainActor
	func sectionIndex(model: PreferencesGeneralModel) -> Int {
		let sections = Self.availableSections(with: model)
		return sections.firstIndex(of: self)!
	}

	@MainActor
	private static func availableSections(with model: PreferencesGeneralModel) -> [Self] {
		var sections = allCases
		if model.hasDismissedSetupInstructions,
		   let setupInstructionsSectionIndex = sections.firstIndex(of: .setupInstructions) {
			sections.remove(at: setupInstructionsSectionIndex)
		}
		if model.hasRomFile,
		   let romSectionIndex = sections.firstIndex(of: .bootstrap) {
			sections.remove(at: romSectionIndex)
		}
		if !UIDevice.isIPad,
		   let iPadMouseSection = sections.firstIndex(of: .iPadMouse) {
			sections.remove(at: iPadMouseSection)
		}
		if !model.supportsHaptics,
		   let hapticsFeedbackSectionIndex = sections.firstIndex(of: .hapticFeedback) {
			sections.remove(at: hapticsFeedbackSectionIndex)
		}

		return sections
	}
}


extension PreferencesGeneralViewController {
	private func set(
		secondFingerClick: Bool? = nil,
		secondFingerSwipe: Bool? = nil,
		bootInHoverMode: Bool? = nil
	) {
		let prevSecondFingerClick = model.secondFingerClick
		let prevSecondFingerSwipe = model.secondFingerSwipe

		let secondFingerClick = secondFingerClick ?? model.secondFingerClick
		var secondFingerSwipe = secondFingerSwipe ?? model.secondFingerSwipe
		var bootInHoverMode = bootInHoverMode ?? model.bootInHoverMode

		if !secondFingerClick {
			secondFingerSwipe = false
			bootInHoverMode = false
		} else if !secondFingerSwipe {
			bootInHoverMode = false
		}

		model.secondFingerClick = secondFingerClick
		model.secondFingerSwipe = secondFingerSwipe
		model.bootInHoverMode = bootInHoverMode

		let sectionIndex = SectionType.secondFinger.sectionIndex(model: model)

		tableView.performBatchUpdates {
			if !prevSecondFingerClick,
			   secondFingerClick {
				tableView.insertRows(at: [
					.init(row: 2, section: sectionIndex),
					.init(row: 3, section: sectionIndex)
				], with: .fade)
				tableView.reloadRows(at: [
					.init(row: 1, section: sectionIndex)
				], with: .fade)
			} else if prevSecondFingerClick,
					  !secondFingerClick {
				tableView.deleteRows(at: [
					.init(row: 2, section: sectionIndex),
					.init(row: 3, section: sectionIndex)
				], with: .fade)
				tableView.reloadRows(at: [
					.init(row: 1, section: sectionIndex)
				], with: .fade)
			}
			if !prevSecondFingerSwipe,
			   secondFingerSwipe {
				tableView.insertRows(at: [
					.init(row: 4, section: sectionIndex),
					.init(row: 5, section: sectionIndex)
				], with: .fade)
				if secondFingerClick {
					tableView.reloadRows(at: [
						.init(row: 3, section: sectionIndex)
					], with: .fade)
				}
			} else if prevSecondFingerSwipe,
					  !secondFingerSwipe {
				tableView.deleteRows(at: [
					.init(row: 4, section: sectionIndex),
					.init(row: 5, section: sectionIndex)
				], with: .fade)
				if secondFingerClick {
					tableView.reloadRows(at: [
						.init(row: 3, section: sectionIndex)
					], with: .fade)
				}
			}
		}
	}
}
