//
//  FeedInspectorViewController.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 1/20/18.
//  Copyright © 2018 Ranchero Software. All rights reserved.
//

import AppKit
import Articles
import Account
import UserNotifications

@MainActor final class FeedInspectorViewController: NSViewController, Inspector {

	@IBOutlet weak var iconView: IconView!
	@IBOutlet weak var nameTextField: NSTextField?
	@IBOutlet weak var homePageURLTextField: NSTextField?
	@IBOutlet weak var urlTextField: NSTextField?
	@IBOutlet weak var isNotifyAboutNewArticlesCheckBox: NSButton!
	@IBOutlet weak var isReaderViewAlwaysOnCheckBox: NSButton?
	
	private var feed: Feed? {
		didSet {
			if feed != oldValue {
				updateUI()
			}
		}
	}

	private var userNotificationSettings: UNNotificationSettings?

	// MARK: Inspector

	let isFallbackInspector = false
	var objects: [Any]? {
		didSet {
			renameFeedIfNecessary()
			updateFeed()
		}
	}
	var windowTitle: String = NSLocalizedString("window.title.feed-inspector", comment: "Feed Inspector")

	func canInspect(_ objects: [Any]) -> Bool {
		return objects.count == 1 && objects.first is Feed
	}

	// MARK: NSViewController

	override func viewDidLoad() {
		updateUI()
		NotificationCenter.default.addObserver(self, selector: #selector(imageDidBecomeAvailable(_:)), name: .ImageDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(updateUI), name: .DidUpdateFeedPreferencesFromContextMenu, object: nil)
	}
	
	override func viewDidAppear() {
		updateNotificationSettings()
	}
	
	override func viewDidDisappear() {
		renameFeedIfNecessary()
	}
	
	// MARK: Actions
	@IBAction func isNotifyAboutNewArticlesChanged(_ sender: Any) {
		guard userNotificationSettings != nil else  {
			DispatchQueue.main.async {
				self.isNotifyAboutNewArticlesCheckBox.setNextState()
			}
			return
		}
		
		UNUserNotificationCenter.current().getNotificationSettings { (settings) in
			self.updateNotificationSettings()
			
			if settings.authorizationStatus == .denied {
				DispatchQueue.main.async {
					self.isNotifyAboutNewArticlesCheckBox.setNextState()
					self.showNotificationsDeniedError()
				}
			} else if settings.authorizationStatus == .authorized {
				DispatchQueue.main.async {
					self.feed?.isNotifyAboutNewArticles = (self.isNotifyAboutNewArticlesCheckBox?.state ?? .off) == .on ? true : false
				}
			} else {
				UNUserNotificationCenter.current().requestAuthorization(options: [.badge, .sound, .alert]) { (granted, error) in
					self.updateNotificationSettings()
					if granted {
						DispatchQueue.main.async {
							self.feed?.isNotifyAboutNewArticles = (self.isNotifyAboutNewArticlesCheckBox?.state ?? .off) == .on ? true : false
							NSApplication.shared.registerForRemoteNotifications()
						}
					} else {
						DispatchQueue.main.async {
							self.isNotifyAboutNewArticlesCheckBox.setNextState()
						}
					}
				}
			}
		}
	}
	
	@IBAction func isReaderViewAlwaysOnChanged(_ sender: Any) {
		feed?.isArticleExtractorAlwaysOn = (isReaderViewAlwaysOnCheckBox?.state ?? .off) == .on ? true : false
	}
	
	// MARK: Notifications

	@objc func imageDidBecomeAvailable(_ note: Notification) {
		updateImage()
	}
	
}

extension FeedInspectorViewController: NSTextFieldDelegate {

	func controlTextDidEndEditing(_ note: Notification) {
		renameFeedIfNecessary()
	}
	
}

private extension FeedInspectorViewController {

	func updateFeed() {
		guard let objects = objects, objects.count == 1, let singleFeed = objects.first as? Feed else {
			feed = nil
			return
		}
		feed = singleFeed
	}

	
	@objc func updateUI() {
		updateImage()
		updateName()
		updateHomePageURL()
		updateFeedURL()
		updateNotifyAboutNewArticles()
		updateIsReaderViewAlwaysOn()
		windowTitle = feed?.nameForDisplay ?? NSLocalizedString("window.title.feed-inspector", comment: "Feed Inspector")
		view.needsLayout = true
		if feed != nil {
			isReaderViewAlwaysOnCheckBox?.isEnabled = true
		}
	}

	func updateImage() {
		guard let feed = feed, let iconView = iconView else {
			return
		}
		iconView.iconImage = IconImageCache.shared.imageForFeed(feed)
	}

	func updateName() {
		guard let nameTextField = nameTextField else {
			return
		}

		let name = feed?.editedName ?? feed?.name ?? ""
		if nameTextField.stringValue != name {
			nameTextField.stringValue = name
		}
	}

	func updateHomePageURL() {
		homePageURLTextField?.stringValue = feed?.homePageURL?.decodedURLString ?? ""
	}

	func updateFeedURL() {
		urlTextField?.stringValue = feed?.url.decodedURLString ?? ""
	}

	func updateNotifyAboutNewArticles() {
		isNotifyAboutNewArticlesCheckBox?.title = feed?.notificationDisplayName ?? NSLocalizedString("checkbox.title.show-new-article-notifications", comment: "Show notifications for new articles")
		isNotifyAboutNewArticlesCheckBox?.state = (feed?.isNotifyAboutNewArticles ?? false) ? .on : .off
	}

	func updateIsReaderViewAlwaysOn() {
		isReaderViewAlwaysOnCheckBox?.state = (feed?.isArticleExtractorAlwaysOn ?? false) ? .on : .off
	}

	func updateNotificationSettings() {
		UNUserNotificationCenter.current().getNotificationSettings { (settings) in
			self.userNotificationSettings = settings
			if settings.authorizationStatus == .authorized {
				DispatchQueue.main.async {
					NSApplication.shared.registerForRemoteNotifications()
				}
			}
		}
	}

	func showNotificationsDeniedError() {
		let updateAlert = NSAlert()
		updateAlert.alertStyle = .informational
		updateAlert.messageText = NSLocalizedString("alert.title.enable-notifications", comment: "Enable Notifications")
		updateAlert.informativeText = NSLocalizedString("alert.message.enable-notifications-in-system-settings", comment: "To enable notifications, open Notifications in System Settings, then find NetNewsWire in the list.")
		updateAlert.addButton(withTitle: NSLocalizedString("button.title.open-system-settings", comment: "Open System Settings"))
		updateAlert.addButton(withTitle: NSLocalizedString("button.title.close", comment: "Close"))
		let modalResponse = updateAlert.runModal()
		if modalResponse == .alertFirstButtonReturn {
			NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
		}
	}

	func renameFeedIfNecessary() {
		guard let feed,
			  let account = feed.account,
			  let newName = nameTextField?.stringValue,
			  feed.nameForDisplay != newName else {
			return
		}
		
		Task { @MainActor in
			do {
				try await account.rename(feed, to: newName)
				self.windowTitle = feed.nameForDisplay
			} catch {
				self.presentError(error)
			}
		}
	}
}
