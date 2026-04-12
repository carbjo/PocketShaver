//
//  PreferencesNetworkViewController.swift
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-15.
//

import UIKit
import Combine

class PreferencesNetworkViewController: UITableViewController {

	enum Section {
		case main
	}

	enum Row: Hashable {
		// OS version warning
		case osVersionWarningCell

		// Service type
		case serviceTypeSlirp
		case serviceTypeBonjour
		case serviceTypeChangeWarning

		// Bonjour role
		case bonjourRolePicker

		// Bonjour shared rows
		case bonjourThisDeviceName(String, Bool)
		case bonjourLanRoomColumnDescription

		// Bonjour host
		case bonjourHostInformation
		case bonjourHostRoomEmptyState
		case bonjourHostRoomHost(String)
		case bonjourHostRoomClient(ConnectedPeer)

		// Bonjour client browsing
		case bonjourClientHostListEmptyState
		case bonjourClientHostListColumnDescription
		case bonjourClientHostListRouter(ConnectedPeer, Bool)

		// Bonjour client in host room
		case bonjourClientHostRoomHostName(ConnectedPeer)
		case bonjourClientHostRoomHostHostPeer(ConnectedPeer, Bool)
		case bonjourClientHostRoomHostThisDevice(BonjourManager.Client)
		case bonjourClientHostRoomHostClientListOtherClient(BonjourManager.Client)
	}

	private let model: PreferencesNetworkModel
	private var anyCancellables = Set<AnyCancellable>()

	private var dataSource: TableViewDiffableDataSource<Section, Row>!

	init(
		mode: PreferencesLaunchMode
	) {
		model = .init(mode: mode)

		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) { fatalError() }

	override func viewDidLoad() {
		super.viewDidLoad()

		tableView.showsVerticalScrollIndicator = false
		view.backgroundColor = Colors.primaryBackground
		view.translatesAutoresizingMaskIntoConstraints = false

		setupDataSource()
		listenToChanges()
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)

		model.reloadData()
	}

	private func listenToChanges() {
		model.changeSubject.sink { [weak self] change in
			guard let self else { return }
			switch change {
			case .didUpdate:
				reloadData()
			}
		}.store(in: &anyCancellables)
	}

	private func setupDataSource() {
		dataSource = .init(tableView: tableView) { [weak self] tableView, indexPath, itemIdentifier in
			guard let self else { return UITableViewCell() }
			switch itemIdentifier {
			case .osVersionWarningCell:
				return PreferencesNetworkOSVersionWarningCell { [weak self] in
					self?.model.hasDismissedOsWarning = true
				}
			case .serviceTypeSlirp:
				return PreferencesNetworkServiceTypeCell(
					serviceType: .slirp,
					isSelected: model.serviceType == .slirp
				)
			case .serviceTypeBonjour:
				return PreferencesNetworkServiceTypeCell(
					serviceType: .bonjour,
					isSelected: model.serviceType == .bonjour
				)
			case .serviceTypeChangeWarning:
				return PreferencesCardInformationCell(
					text: "It might take a while before Mac OS assigns the new IP address. You can force this by restarting or changing configuration inside the <mark>TCP/IP</mark> app.",
					tagConfig: .init(
						highlightedAppearance: .init(
							font: Fonts.geneva.ofSize(14)!,
							color: Colors.primaryText
						)
					)
				)
			case .bonjourRolePicker:
				return PreferencesNetworkBonjourRolePickerCell(
					initialBonjourRole: model.bonjourRole
				) { [weak self] newRole in
					guard let self,
						  model.bonjourRole != newRole else { return }
					model.bonjourRole = newRole
					reloadData()
				}
			case .bonjourThisDeviceName(let thisDeviceName, let isConnected):
				let text = isConnected ?
				"Your device appears as \(thisDeviceName). <link>Change</link>" :
				"Your device will appear as \(thisDeviceName). <link>Change</link>"
				return PreferencesInformationCell(
					text: text
				) { [weak self] in
					self?.presentChangeBonjourName()
				}
			case .bonjourHostInformation:
				return PreferencesInformationCell(
					text: "Your device will have routing responbilities. Can have performance impact.",
					lowerMargin: .none
				)
			case .bonjourHostRoomEmptyState:
				return PreferencesEmptyStateCell(
					title: "No clients connected",
					separatorHidden: true
				)
			case .bonjourHostRoomHost(let name):
				return PreferencesInformationCell(
					text: "<img yOffset=-5/>  \(name) (host) (this device)",
					upperMargin: .medium,
					tagConfig: .init(
						images: [Assets.bonjour.withRenderingMode(.alwaysTemplate)]
					)
				)
			case .bonjourHostRoomClient(let connectedPeer):
				return PreferencesInformationCell(
					text: "<img yOffset=-5/>  \(connectedPeer.name)",
					upperMargin: .medium,
					tagConfig: .init(
						images: [Assets.bonjour.withRenderingMode(.alwaysTemplate)]
					)
				)
			case .bonjourClientHostListEmptyState:
				return PreferencesEmptyStateCell(
					title: "Looking for hosts",
					separatorHidden: true
				)
			case .bonjourClientHostListColumnDescription:
				return PreferencesGeneralLanColumnsDescriptionCell(
					columnTitle: "Available hosts"
				)
			case .bonjourClientHostListRouter(let connectedPeer, let separatorHidden):
				return PreferencesNetworkRouterCell(
					title: "\(connectedPeer.name)",
					separatorHidden: separatorHidden
				)
			case .bonjourLanRoomColumnDescription:
				return PreferencesGeneralLanColumnsDescriptionCell(
					columnTitle: "Peers in connected LAN"
				)
			case .bonjourClientHostRoomHostName(let routerPeer):
				return PreferencesInformationCell(
					text: "Connected to LAN hosted by \(routerPeer.name). <link>Leave</link>",
					upperMargin: .medium,
					lowerMargin: .none
				) { [weak self] in
					guard let self else { return }
					model.resetSelectedRouterPeer()
					reloadData()
				}
			case .bonjourClientHostRoomHostHostPeer(let routerPeer, let isAutojoinOn):
				if isAutojoinOn {
					return PreferencesInformationCell(
						text: "<img yOffset=-5/>  \(routerPeer.name) (host) <link>Autojoin <img/></link>",
						upperMargin: .medium,
						tagConfig: .init(
							boldAppearance: .init(font: .boldSystemFont(ofSize: 14), color: Colors.okColor),
							images: [
								Assets.bonjour.withRenderingMode(.alwaysTemplate),
								ImageResource.checkmarkCircleFill.asSymbolImage().withTintColor(Colors.okColor)
							],
							highlightedImages: [
								Assets.bonjour.withRenderingMode(.alwaysTemplate),
								ImageResource.checkmarkCircleFill.asSymbolImage().withTintColor(Colors.highlightedText)
							]
						)
					) { [weak self] in
						self?.model.isSelectedRouterPeerAutojoinEnabled = false
					}
				} else {
					return PreferencesInformationCell(
						text: "<img yOffset=-5/>  \(routerPeer.name) (host) <link>Autojoin</link>",
						upperMargin: .medium,
						tagConfig: .init(
							images: [Assets.bonjour.withRenderingMode(.alwaysTemplate)]
						)
					) { [weak self] in
						self?.model.isSelectedRouterPeerAutojoinEnabled = true
					}
				}
			case .bonjourClientHostRoomHostThisDevice(let thisDevice):
				return PreferencesInformationCell(
					text: "<img yOffset=-5/>  \(thisDevice.name) (this device)",
					upperMargin: .medium,
					tagConfig: .init(
						images: [Assets.bonjour.withRenderingMode(.alwaysTemplate)]
					)
				)
			case .bonjourClientHostRoomHostClientListOtherClient(let client):
				return PreferencesInformationCell(
					text: "<img yOffset=-5/>  \(client.name)",
					upperMargin: .medium,
					tagConfig: .init(
						images: [Assets.bonjour.withRenderingMode(.alwaysTemplate)]
					)
				)
			}
		}

		dataSource.defaultRowAnimation = .fade
		tableView.dataSource = dataSource

		reloadData()
	}

	private func reloadData() {
		var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()

		snapshot.appendSections([.main])

		if !model.hasDismissedOsWarning {
			snapshot.appendItems([
				.osVersionWarningCell
			])
		}

		snapshot.appendItems([
			.serviceTypeSlirp,
			.serviceTypeBonjour
		])
		if model.shouldDisplayServiceTypeChangeWarning {
			snapshot.appendItems([.serviceTypeChangeWarning])
		}

		if model.serviceType == .slirp {
			dataSource.apply(snapshot)
			return
		}

		snapshot.appendItems([
			.bonjourRolePicker
		])

		switch model.bonjourRole {
		case .host:
			snapshot.appendItems([
				.bonjourHostInformation,
				.bonjourThisDeviceName(model.bonjourName, model.isConnectedToPeers),
				.bonjourLanRoomColumnDescription
			])

			if model.connectedPeers.isEmpty {
				snapshot.appendItems([
					.bonjourHostRoomEmptyState
				])
			} else {
				snapshot.appendItems([
					.bonjourHostRoomHost(model.bonjourName)
				])
				snapshot.appendItems(
					model.connectedPeers.map({ Row.bonjourHostRoomClient($0) })
				)
			}
		case .client:
			if let hostPeer = model.selectedRouterPeer {
				// In host room
				snapshot.appendItems([
					.bonjourClientHostRoomHostName(hostPeer),
					.bonjourThisDeviceName(model.bonjourName, model.isConnectedToPeers),
					.bonjourLanRoomColumnDescription,
					.bonjourClientHostRoomHostHostPeer(hostPeer, model.isSelectedRouterPeerAutojoinEnabled)
				])
				if let thisDevice = model.clientsInSameHostRoom.first(where: { $0.isThisDevice }) {
					snapshot.appendItems([
						.bonjourClientHostRoomHostThisDevice(thisDevice)
					])
				}
				snapshot.appendItems(
					model
						.clientsInSameHostRoom
						.filter({ !$0.isThisDevice })
						.map({ .bonjourClientHostRoomHostClientListOtherClient($0) })
				)
			} else {
				snapshot.appendItems([
					.bonjourThisDeviceName(model.bonjourName, model.isConnectedToPeers),
					.bonjourClientHostListColumnDescription
				])
				// Client browsing for hosts
				if model.connectedPeers.isEmpty {
					snapshot.appendItems([
						.bonjourClientHostListEmptyState
					])
				} else {
					snapshot.appendItems(
						model.connectedPeers.map({
							Row.bonjourClientHostListRouter(
								$0,
								$0 == model.connectedPeers.last // separator hidden
							)
						})
					)
				}
			}
		}

		dataSource.apply(snapshot)
	}

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: true)

		let itemIdentifier = dataSource.itemIdentifier(for: indexPath)

		switch itemIdentifier {
		case .serviceTypeSlirp:
			select(serviceType: .slirp)
		case .serviceTypeBonjour:
			select(serviceType: .bonjour)
		case .bonjourClientHostListRouter(let connectedPeer, _):
			do {
				try model.set(selectedRouterPeer: connectedPeer)
			} catch {
				let alertVC = UIAlertController.with(title: "Error", message: "Router was not available.")
				present(alertVC, animated: true)
			}
		default:
			break
		}

		reloadData()
	}

	override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		let itemIdentifier = dataSource.itemIdentifier(for: indexPath)

		switch itemIdentifier {
		case .serviceTypeSlirp,
				.serviceTypeBonjour,
				.bonjourClientHostListRouter:
			return true
		default:
			return false
		}
	}

	private func select(serviceType: NetworkServiceType) {
		let networkCellIndexPath = dataSource.indexPath(for: .serviceTypeSlirp)!
		let bonjourCellIndexPath = dataSource.indexPath(for: .serviceTypeBonjour)!
		let networkCell = tableView.cellForRow(at: networkCellIndexPath) as? PreferencesNetworkServiceTypeCell
		let bonjourCell = tableView.cellForRow(at: bonjourCellIndexPath) as? PreferencesNetworkServiceTypeCell

		switch serviceType {
		case .slirp:
			networkCell?.configure(isSelected: true)
			bonjourCell?.configure(isSelected: false)
		case .bonjour:
			networkCell?.configure(isSelected: false)
			bonjourCell?.configure(isSelected: true)
		}

		model.serviceType = serviceType
	}

	private func presentChangeBonjourName() {
		let alertVC = UIAlertController(title: "Change LAN device name", message: nil, preferredStyle: .alert)
		alertVC.addTextField() { [weak self] textField in
			textField.autocapitalizationType = .sentences
			textField.text = self?.model.bonjourName
		}
		alertVC.addAction(.init(title: "Cancel", style: .cancel))
		alertVC.addAction(.init(title: "OK", style: .default, handler: { [weak self] _ in
			guard let self,
				  let text = alertVC.textFields?[0].text,
			!text.isEmpty else {
				return
			}

			model.bonjourName = text
		}))

		present(alertVC, animated: true)
	}
}
