//
//  MainTimelineViewController.swift
//  NetNewsWire
//
//  Created by Maurice Parker on 4/8/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit
import WebKit
import SwiftUI
import RSCore
import Account
import Articles

class MainTimelineViewController: UITableViewController, UndoableCommandRunner, MainControllerIdentifiable {

	private var numberOfTextLines = 0
	private var iconSize = IconSize.medium
	private lazy var feedTapGestureRecognizer = UITapGestureRecognizer(target: self, action:#selector(showFeedInspector(_:)))
	
	private var filterButton: UIBarButtonItem!

	@IBOutlet weak var markAllAsReadButton: UIBarButtonItem!

	let refreshProgressModel = RefreshProgressModel()
	lazy var progressBarViewController = UIHostingController(rootView: RefreshProgressView(progressBarMode: refreshProgressModel))
	
	private var refreshProgressItemButton: UIBarButtonItem!
	private var firstUnreadButton: UIBarButtonItem!

	private lazy var dataSource = makeDataSource()
	private let searchController = UISearchController(searchResultsController: nil)
	
	private var markAsReadOnScrollWorkItem: DispatchWorkItem?
	private var markAsReadOnScrollStart: Int?
	private var markAsReadOnScrollEnd: Int?
	private var lastVerticalPosition: CGFloat = 0

	var mainControllerIdentifier = MainControllerIdentifier.mainTimeline

	weak var coordinator: SceneCoordinator!
	var undoableCommands = [UndoableCommand]()

	private let keyboardManager = KeyboardManager(type: .timeline)
	override var keyCommands: [UIKeyCommand]? {
		
		// If the first responder is the WKWebView (PreloadedWebView) we don't want to supply any keyboard
		// commands that the system is looking for by going up the responder chain. They will interfere with
		// the WKWebViews built in hardware keyboard shortcuts, specifically the up and down arrow keys.
		guard let current = UIResponder.currentFirstResponder, !(current is WKWebView) else { return nil }
		
		return keyboardManager.keyCommands
	}
	
	override var canBecomeFirstResponder: Bool {
		return true
	}

	override func viewDidLoad() {
		
		super.viewDidLoad()

		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(statusesDidChange(_:)), name: .StatusesDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(feedIconDidBecomeAvailable(_:)), name: .FeedIconDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(avatarDidBecomeAvailable(_:)), name: .AvatarDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(faviconDidBecomeAvailable(_:)), name: .FaviconDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(userDefaultsDidChange(_:)), name: UserDefaults.didChangeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(contentSizeCategoryDidChange), name: UIContentSizeCategory.didChangeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(displayNameDidChange), name: .DisplayNameDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)

		// Initialize Programmatic Buttons
		filterButton = UIBarButtonItem(image: AppAssets.filterInactiveImage, style: .plain, target: self, action: #selector(toggleFilter(_:)))
		firstUnreadButton = UIBarButtonItem(image: AppAssets.nextUnreadArticleImage, style: .plain, target: self, action: #selector(firstUnread(_:)))
		
		// Setup the Search Controller
		searchController.delegate = self
		searchController.searchResultsUpdater = self
		searchController.obscuresBackgroundDuringPresentation = false
		searchController.searchBar.delegate = self
		searchController.searchBar.placeholder = NSLocalizedString("searchbar.placeholder.searcharticles", comment: "Search Articles")
		
		searchController.searchBar.scopeButtonTitles = [
			NSLocalizedString("searchbar.scope.here", comment: "Title used when describing the search when scoped to the current timeline."),
			NSLocalizedString("searchbar.scope.allarticles", comment: "Title used when desribing the search when scoped to all articles.")
		]
		navigationItem.searchController = searchController
		definesPresentationContext = true

		// Configure the table
		tableView.dataSource = dataSource
		if #available(iOS 15.0, *) {
			tableView.isPrefetchingEnabled = false
		}
		numberOfTextLines = AppDefaults.shared.timelineNumberOfLines
		iconSize = AppDefaults.shared.timelineIconSize
		resetEstimatedRowHeight()

		if let titleView = Bundle.main.loadNibNamed("MasterTimelineTitleView", owner: self, options: nil)?[0] as? MainTimelineTitleView {
			navigationItem.titleView = titleView
		}
		
		refreshControl = UIRefreshControl()
		refreshControl!.addTarget(self, action: #selector(refreshAccounts(_:)), for: .valueChanged)
		refreshControl!.tintColor = .clear

		progressBarViewController.view.backgroundColor = .clear
		progressBarViewController.view.translatesAutoresizingMaskIntoConstraints = false
		refreshProgressItemButton = UIBarButtonItem(customView: progressBarViewController.view)

		configureToolbar()

		resetUI(resetScroll: true)
		
		// Load the table and then scroll to the saved position if available
		applyChanges(animated: false) {
			if let restoreIndexPath = self.coordinator.timelineMiddleIndexPath {
				self.tableView.scrollToRow(at: restoreIndexPath, at: .middle, animated: false)
			}
		}
		
		// Disable swipe back on iPad Mice
		guard let gesture = self.navigationController?.interactivePopGestureRecognizer as? UIPanGestureRecognizer else {
			return
		}
		gesture.allowedScrollTypesMask = []
		
	}
	
	override func viewWillAppear(_ animated: Bool) {
		navigationController?.isToolbarHidden = false

		// If the nav bar is hidden, fade it in to avoid it showing stuff as it is getting laid out
		if navigationController?.navigationBar.isHidden ?? false {
			navigationController?.navigationBar.alpha = 0
		}
		
		super.viewWillAppear(animated)
	}
	
	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(true)

		if navigationController?.navigationBar.alpha == 0 {
			UIView.animate(withDuration: 0.5) {
				self.navigationController?.navigationBar.alpha = 1
			}
		}
	}
	
	// MARK: Actions
	
	@objc func openInBrowser(_ sender: Any?) {
		coordinator.showBrowserForCurrentArticle()
	}

	@objc func openInAppBrowser(_ sender: Any?) {
		coordinator.showInAppBrowser()
	}
	
	@IBAction func toggleFilter(_ sender: Any) {
		coordinator.toggleReadArticlesFilter()
	}
	
	@IBAction func markAllAsRead(_ sender: Any) {
		let title = NSLocalizedString("button.title.mark-all-as-read.titlecase", comment: "Mark All as Read")
		
		if let source = sender as? UIBarButtonItem {
			MarkAsReadAlertController.confirm(self, coordinator: coordinator, confirmTitle: title, sourceType: source) { [weak self] in
				self?.coordinator.markAllAsReadInTimeline()
			}
		}
		
		if let _ = sender as? UIKeyCommand {
			guard let indexPath = tableView.indexPathForSelectedRow, let contentView = tableView.cellForRow(at: indexPath)?.contentView else {
				return
			}
			
			MarkAsReadAlertController.confirm(self, coordinator: coordinator, confirmTitle: title, sourceType: contentView) { [weak self] in
				self?.coordinator.markAllAsReadInTimeline()
			}
		}
	}
	
	@IBAction func firstUnread(_ sender: Any) {
		coordinator.selectFirstUnread()
	}
	
	@objc func refreshAccounts(_ sender: Any) {
		refreshControl?.endRefreshing()

		// This is a hack to make sure that an error dialog doesn't interfere with dismissing the refreshControl.
		// If the error dialog appears too closely to the call to endRefreshing, then the refreshControl never disappears.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			appDelegate.manualRefresh(errorHandler: ErrorHandler.present(self))
		}
	}
	
	// MARK: Keyboard shortcuts
	
	@objc func selectNextUp(_ sender: Any?) {
		coordinator.selectPrevArticle()
	}

	@objc func selectNextDown(_ sender: Any?) {
		coordinator.selectNextArticle()
	}

	@objc func navigateToSidebar(_ sender: Any?) {
		coordinator.navigateToFeeds()
	}
	
	@objc func navigateToDetail(_ sender: Any?) {
		coordinator.navigateToDetail()
	}
	
	@objc func showFeedInspector(_ sender: Any?) {
		coordinator.showFeedInspector()
	}

	// MARK: API
	
	func restoreSelectionIfNecessary(adjustScroll: Bool) {
		if let article = coordinator.currentArticle, let indexPath = dataSource.indexPath(for: article) {
			if adjustScroll {
				tableView.selectRowAndScrollIfNotVisible(at: indexPath, animations: [])
			} else {
				tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
			}
		}
	}

	func reinitializeArticles(resetScroll: Bool) {
		resetUI(resetScroll: resetScroll)
	}
	
	func reloadArticles(animated: Bool) {
		applyChanges(animated: animated)
	}
	
	func updateArticleSelection(animations: Animations) {
		if let article = coordinator.currentArticle, let indexPath = dataSource.indexPath(for: article) {
			if tableView.indexPathForSelectedRow != indexPath {
				tableView.selectRowAndScrollIfNotVisible(at: indexPath, animations: animations)
			}
		} else {
			tableView.selectRow(at: nil, animated: animations.contains(.select), scrollPosition: .none)
		}
		
		updateUI()
	}

	func updateUI() {
		refreshProgressModel.update()
		updateTitleUnreadCount()
		updateToolbar()
	}
	
	func hideSearch() {
		navigationItem.searchController?.isActive = false
	}

	func showSearchAll() {
		navigationItem.searchController?.isActive = true
		navigationItem.searchController?.searchBar.selectedScopeButtonIndex = 1
		navigationItem.searchController?.searchBar.becomeFirstResponder()
	}
	
	func focus() {
		becomeFirstResponder()
	}

	// MARK: - Table view

	override func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
		guard let article = dataSource.itemIdentifier(for: indexPath) else { return nil }
		guard !article.status.read || article.isAvailableToMarkUnread else { return nil }

		// Set up the read action
		let readTitle = article.status.read ?
		NSLocalizedString("button.title.mark-as-unread.titlecase", comment: "Mark as Unread. Used to mark an article unread") :
		NSLocalizedString("button.title.mark-as-read.titlecase", comment: "Mark as Read. Used to mark an article Read")
		
		let readAction = UIContextualAction(style: .normal, title: readTitle) { [weak self] (action, view, completion) in
			self?.coordinator.toggleRead(article)
			completion(true)
		}
		
		readAction.image = article.status.read ? AppAssets.circleClosedImage : AppAssets.circleOpenImage
		readAction.backgroundColor = AppAssets.primaryAccentColor
		
		return UISwipeActionsConfiguration(actions: [readAction])
	}
	
	override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
		
		guard let article = dataSource.itemIdentifier(for: indexPath) else { return nil }
		
		// Set up the star action
		let starTitle = article.status.starred ?
		NSLocalizedString("button.title.unstar", comment: "Unstar. Used when removing the starred status from an article") :
		NSLocalizedString("button.title.star", comment: "Star. Used when marking an article as starred.")
		
		let starAction = UIContextualAction(style: .normal, title: starTitle) { [weak self] (action, view, completion) in
			self?.coordinator.toggleStar(article)
			completion(true)
		}
		
		starAction.image = article.status.starred ? AppAssets.starOpenImage : AppAssets.starClosedImage
		starAction.backgroundColor = AppAssets.starColor
		
		// Set up the read action
		let moreTitle = NSLocalizedString("button.title.more", comment: "More")
		let moreAction = UIContextualAction(style: .normal, title: moreTitle) { [weak self] (action, view, completion) in
			
			if let self = self {
			
				let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
				if let popoverController = alert.popoverPresentationController {
					popoverController.sourceView = view
					popoverController.sourceRect = CGRect(x: view.frame.size.width/2, y: view.frame.size.height/2, width: 1, height: 1)
				}

				if let action = self.markAboveAsReadAlertAction(article, indexPath: indexPath, completion: completion) {
					alert.addAction(action)
				}

				if let action = self.markBelowAsReadAlertAction(article, indexPath: indexPath, completion: completion) {
					alert.addAction(action)
				}
				
				if let action = self.discloseFeedAlertAction(article, completion: completion) {
					alert.addAction(action)
				}
				
				if let action = self.markAllInFeedAsReadAlertAction(article, indexPath: indexPath, completion: completion) {
					alert.addAction(action)
				}

				if let action = self.openInBrowserAlertAction(article, completion: completion) {
					alert.addAction(action)
				}

				if let action = self.shareAlertAction(article, indexPath: indexPath, completion: completion) {
					alert.addAction(action)
				}

				let cancelTitle = NSLocalizedString("button.title.cancel", comment: "Cancel")
				alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in
					completion(true)
				})

				self.present(alert, animated: true)
				
			}
			
		}
		
		moreAction.image = AppAssets.moreImage
		moreAction.backgroundColor = UIColor.systemGray

		return UISwipeActionsConfiguration(actions: [starAction, moreAction])
		
	}

	override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {

		guard let article = dataSource.itemIdentifier(for: indexPath) else { return nil }
		
		return UIContextMenuConfiguration(identifier: indexPath.row as NSCopying, previewProvider: nil, actionProvider: { [weak self] suggestedActions in

			guard let self = self else { return nil }
			
			var menuElements = [UIMenuElement]()
			
			var markActions = [UIAction]()
			if let action = self.toggleArticleReadStatusAction(article) {
				markActions.append(action)
			}
			markActions.append(self.toggleArticleStarStatusAction(article))
			if let action = self.markAboveAsReadAction(article, indexPath: indexPath) {
				markActions.append(action)
			}
			if let action = self.markBelowAsReadAction(article, indexPath: indexPath) {
				markActions.append(action)
			}
			menuElements.append(UIMenu(title: "", options: .displayInline, children: markActions))
			
			var secondaryActions = [UIAction]()
			if let action = self.discloseFeedAction(article) {
				secondaryActions.append(action)
			}
			if let action = self.markAllInFeedAsReadAction(article, indexPath: indexPath) {
				secondaryActions.append(action)
			}
			if !secondaryActions.isEmpty {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: secondaryActions))
			}
			
			var copyActions = [UIAction]()
			if let action = self.copyArticleURLAction(article) {
				copyActions.append(action)
			}
			if let action = self.copyExternalURLAction(article) {
				copyActions.append(action)
			}
			if !copyActions.isEmpty {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: copyActions))
			}
			
			if let action = self.openInBrowserAction(article) {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: [action]))
			}
			
			if let action = self.shareAction(article, indexPath: indexPath) {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: [action]))
			}
			
			return UIMenu(title: "", children: menuElements)

		})
		
	}

	override func tableView(_ tableView: UITableView, previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
		guard let row = configuration.identifier as? Int,
			let cell = tableView.cellForRow(at: IndexPath(row: row, section: 0)) else {
				return nil
		}
		
		return UITargetedPreview(view: cell, parameters: CroppingPreviewParameters(view: cell))
	}

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		becomeFirstResponder()
		let article = dataSource.itemIdentifier(for: indexPath)
		coordinator.selectArticle(article, animations: [.scroll, .select, .navigation])
	}
	
	override func scrollViewDidScroll(_ scrollView: UIScrollView) {
		coordinator.timelineMiddleIndexPath = tableView.middleVisibleRow()
		markAsReadOnScroll()
	}
	
	// MARK: Notifications

	@objc dynamic func unreadCountDidChange(_ notification: Notification) {
		updateUI()
	}
	
	@objc func statusesDidChange(_ note: Notification) {
		guard let articleIDs = note.userInfo?[Account.UserInfoKey.articleIDs] as? Set<String>, !articleIDs.isEmpty else {
			return
		}

		let visibleArticles = tableView.indexPathsForVisibleRows!.compactMap { return dataSource.itemIdentifier(for: $0) }
		let visibleUpdatedArticles = visibleArticles.filter { articleIDs.contains($0.articleID) }

		for article in visibleUpdatedArticles {
			if let indexPath = dataSource.indexPath(for: article) {
				if let cell = tableView.cellForRow(at: indexPath) as? MainTimelineTableViewCell {
					configure(cell, article: article, indexPath: indexPath)
				}
			}
		}
	}

	@objc func feedIconDidBecomeAvailable(_ note: Notification) {
		
		if let titleView = navigationItem.titleView as? MainTimelineTitleView {
			titleView.iconView.iconImage = coordinator.timelineIconImage
		}
		
		guard let feed = note.userInfo?[UserInfoKey.feed] as? Feed else {
			return
		}
		guard let indexPathsForVisibleRows = tableView.indexPathsForVisibleRows else {
			return
		}
		for indexPath in indexPathsForVisibleRows {
			guard let article = dataSource.itemIdentifier(for: indexPath) else {
				continue
			}
			if article.feed == feed, let cell = tableView.cellForRow(at: indexPath) as? MainTimelineTableViewCell, let image = iconImageFor(article) {
				cell.setIconImage(image)
			}
		}
	}

	@objc func avatarDidBecomeAvailable(_ note: Notification) {
		guard coordinator.showIcons, let avatarURL = note.userInfo?[UserInfoKey.url] as? String else {
			return
		}
		guard let indexPathsForVisibleRows = tableView.indexPathsForVisibleRows else {
			return
		}
		for indexPath in indexPathsForVisibleRows {
			guard let article = dataSource.itemIdentifier(for: indexPath), let authors = article.authors, !authors.isEmpty else {
				continue
			}
			for author in authors {
				if author.avatarURL == avatarURL, let cell = tableView.cellForRow(at: indexPath) as? MainTimelineTableViewCell, let image = iconImageFor(article) {
					cell.setIconImage(image)
				}
			}
		}
	}

	@objc func faviconDidBecomeAvailable(_ note: Notification) {
		if let titleView = navigationItem.titleView as? MainTimelineTitleView {
			titleView.iconView.iconImage = coordinator.timelineIconImage
		}
		if coordinator.showIcons {
			queueReloadAvailableCells()
		}
	}

	@objc func userDefaultsDidChange(_ note: Notification) {
		DispatchQueue.main.async {
			if self.numberOfTextLines != AppDefaults.shared.timelineNumberOfLines || self.iconSize != AppDefaults.shared.timelineIconSize {
				self.numberOfTextLines = AppDefaults.shared.timelineNumberOfLines
				self.iconSize = AppDefaults.shared.timelineIconSize
				self.resetEstimatedRowHeight()
				self.reloadAllVisibleCells()
			}
			self.updateToolbar()
		}
	}
	
	@objc func contentSizeCategoryDidChange(_ note: Notification) {
		reloadAllVisibleCells()
	}
	
	@objc func displayNameDidChange(_ note: Notification) {
		if let titleView = navigationItem.titleView as? MainTimelineTitleView {
			titleView.label.text = coordinator.timelineFeed?.nameForDisplay
		}
	}
	
	@objc func willEnterForeground(_ note: Notification) {
		updateUI()
	}
	
	// MARK: Reloading
	
	func queueReloadAvailableCells() {
		CoalescingQueue.standard.add(self, #selector(reloadAllVisibleCells))
	}

	@objc private func reloadAllVisibleCells() {
		let visibleArticles = tableView.indexPathsForVisibleRows!.compactMap { return dataSource.itemIdentifier(for: $0) }
		reloadCells(visibleArticles)
	}
	
	private func reloadCells(_ articles: [Article]) {
		var snapshot = dataSource.snapshot()
		snapshot.reloadItems(articles)
		dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
			self?.restoreSelectionIfNecessary(adjustScroll: false)
		}
	}

	// MARK: Cell Configuring

	private func resetEstimatedRowHeight() {
		
		let longTitle = "But I must explain to you how all this mistaken idea of denouncing pleasure and praising pain was born and I will give you a complete account of the system, and expound the actual teachings of the great explorer of the truth, the architect of human happiness. No one rejects, dislikes, or avoids pleasure itself, because it is pleasure, but because those who do not know how to pursue pleasure rationally encounter consequences that are extremely painful. Nor again is there anyone who loves or pursues or desires to obtain pain of itself, because it is pain, but because occasionally circumstances occur in which toil and pain can procure him some great pleasure. To take a trivial example, which of us ever undertakes laborious physical exercise, except to obtain some advantage from it? But who has any right to find fault with a man who chooses to enjoy a pleasure that has no annoying consequences, or one who avoids a pain that produces no resultant pleasure?"
		
		let prototypeID = "prototype"
		let status = ArticleStatus(articleID: prototypeID, read: false, starred: false, dateArrived: Date())
		let prototypeArticle = Article(accountID: prototypeID, articleID: prototypeID, feedID: prototypeID, uniqueID: prototypeID, title: longTitle, contentHTML: nil, contentText: nil, url: nil, externalURL: nil, summary: nil, imageURL: nil, datePublished: nil, dateModified: nil, authors: nil, status: status)
		
		let prototypeCellData = MainTimelineCellData(article: prototypeArticle, showFeedName: .feed, feedName: "Prototype Feed Name", byline: nil, iconImage: nil, showIcon: false, featuredImage: nil, numberOfLines: numberOfTextLines, iconSize: iconSize, hideSeparator: false)
		
		if UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory {
			let layout = MainTimelineAccessibilityCellLayout(width: tableView.bounds.width, insets: tableView.safeAreaInsets, cellData: prototypeCellData)
			tableView.estimatedRowHeight = layout.height
		} else {
			let layout = MainTimelineDefaultCellLayout(width: tableView.bounds.width, insets: tableView.safeAreaInsets, cellData: prototypeCellData)
			tableView.estimatedRowHeight = layout.height
		}
		
	}
	
}

// MARK: Searching

extension MainTimelineViewController: UISearchControllerDelegate {

	func willPresentSearchController(_ searchController: UISearchController) {
		coordinator.beginSearching()
		searchController.searchBar.showsScopeBar = true
	}

	func willDismissSearchController(_ searchController: UISearchController) {
		coordinator.endSearching()
		searchController.searchBar.showsScopeBar = false
	}

}

extension MainTimelineViewController: UISearchResultsUpdating {

	func updateSearchResults(for searchController: UISearchController) {
		let searchScope = SearchScope(rawValue: searchController.searchBar.selectedScopeButtonIndex)!
		coordinator.searchArticles(searchController.searchBar.text!, searchScope)
	}

}

extension MainTimelineViewController: UISearchBarDelegate {
	func searchBar(_ searchBar: UISearchBar, selectedScopeButtonIndexDidChange selectedScope: Int) {
		let searchScope = SearchScope(rawValue: selectedScope)!
		coordinator.searchArticles(searchBar.text!, searchScope)
	}
}

// MARK: Private

private extension MainTimelineViewController {

	func configureToolbar() {		
		guard splitViewController?.isCollapsed ?? true else {
			return
		}
		
		toolbarItems?.insert(refreshProgressItemButton, at: 2)
	}

	func resetUI(resetScroll: Bool) {
		
		title = coordinator.timelineFeed?.nameForDisplay ?? "Timeline"

		if let titleView = navigationItem.titleView as? MainTimelineTitleView {
			let timelineIconImage = coordinator.timelineIconImage
			titleView.iconView.iconImage = timelineIconImage
			if let preferredColor = timelineIconImage?.preferredColor {
				titleView.iconView.tintColor = UIColor(cgColor: preferredColor)
			} else {
				titleView.iconView.tintColor = nil
			}
			
			titleView.label.text = coordinator.timelineFeed?.nameForDisplay
			updateTitleUnreadCount()

			if coordinator.timelineFeed is Feed {
				titleView.buttonize()
				titleView.addGestureRecognizer(feedTapGestureRecognizer)
			} else {
				titleView.debuttonize()
				titleView.removeGestureRecognizer(feedTapGestureRecognizer)
			}
			
			navigationItem.titleView = titleView
		}

		switch coordinator.timelineDefaultReadFilterType {
		case .none, .read:
			navigationItem.rightBarButtonItem = filterButton
		case .alwaysRead:
			navigationItem.rightBarButtonItem = nil
		}
		
		if coordinator.isReadArticlesFiltered {
			filterButton?.image = AppAssets.filterActiveImage
			filterButton?.accLabelText = NSLocalizedString("label.accessibility.selected-filter-read-artciles", comment: "Selected - Filter Read Articles")
		} else {
			filterButton?.image = AppAssets.filterInactiveImage
			filterButton?.accLabelText = NSLocalizedString("label.accessibility.filter-read-artciles", comment: "Filter Read Articles")
		}

		tableView.selectRow(at: nil, animated: false, scrollPosition: .top)

		if resetScroll {
			let snapshot = dataSource.snapshot()
			if snapshot.sectionIdentifiers.count > 0 && snapshot.itemIdentifiers(inSection: 0).count > 0 {
				tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
			}
		}
		
		updateToolbar()
	}
	
	func updateToolbar() {
		guard firstUnreadButton != nil else { return }
		
		markAllAsReadButton.isEnabled = coordinator.canMarkAllAsRead()
		firstUnreadButton.isEnabled = coordinator.isTimelineUnreadAvailable
		
		if coordinator.isRootSplitCollapsed {
			setToolbarItems([markAllAsReadButton, .flexibleSpace(), refreshProgressItemButton, .flexibleSpace(), firstUnreadButton], animated: false)
		} else {
			setToolbarItems([markAllAsReadButton, .flexibleSpace()], animated: false)
		}
	}
	
	func updateTitleUnreadCount() {
		if let titleView = navigationItem.titleView as? MainTimelineTitleView {
			titleView.unreadCountView.unreadCount = coordinator.timelineUnreadCount
		}
	}
	
	func applyChanges(animated: Bool, completion: (() -> Void)? = nil) {
		lastVerticalPosition = 0
		
		if coordinator.articles.count == 0 {
			tableView.rowHeight = tableView.estimatedRowHeight
		} else {
			tableView.rowHeight = UITableView.automaticDimension
		}
		
        var snapshot = NSDiffableDataSourceSnapshot<Int, Article>()
		snapshot.appendSections([0])
		snapshot.appendItems(coordinator.articles, toSection: 0)

		dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
			self?.restoreSelectionIfNecessary(adjustScroll: false)
			completion?()
		}
	}
	
	func makeDataSource() -> UITableViewDiffableDataSource<Int, Article> {
		let dataSource: UITableViewDiffableDataSource<Int, Article> =
			MainTimelineDataSource(tableView: tableView, cellProvider: { [weak self] tableView, indexPath, article in
				let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath) as! MainTimelineTableViewCell
				self?.configure(cell, article: article, indexPath: indexPath)
				return cell
			})
		dataSource.defaultRowAnimation = .middle
		return dataSource
    }
	
	func configure(_ cell: MainTimelineTableViewCell, article: Article, indexPath: IndexPath) {
		let iconImage = iconImageFor(article)
		let featuredImage = featuredImageFor(article)
		
		let showFeedNames = coordinator.showFeedNames
		let showIcon = coordinator.showIcons && iconImage != nil
		let hideSeparater = indexPath.row == coordinator.articles.count - 1
		
		cell.cellData = MainTimelineCellData(article: article, showFeedName: showFeedNames, feedName: article.feed?.nameForDisplay, byline: article.byline(), iconImage: iconImage, showIcon: showIcon, featuredImage: featuredImage, numberOfLines: numberOfTextLines, iconSize: iconSize, hideSeparator: hideSeparater)
	}
	
	func iconImageFor(_ article: Article) -> IconImage? {
		if !coordinator.showIcons {
			return nil
		}
		return article.iconImage()
	}
	
	func featuredImageFor(_ article: Article) -> UIImage? {
		if let link = article.imageLink, let data = appDelegate.imageDownloader.image(for: link) {
			return RSImage(data: data)
		}
		return nil
	}
	
	func markAsReadOnScroll() {
		// Only try to mark if we are scrolling up
		defer {
			lastVerticalPosition = tableView.contentOffset.y
		}
		guard lastVerticalPosition < tableView.contentOffset.y else {
			return
		}
		
		// Implement Mark As Read on Scroll where we mark after the leading edge goes a little beyond the safe area inset
		guard AppDefaults.shared.markArticlesAsReadOnScroll,
			  lastVerticalPosition < tableView.contentOffset.y,
			  let firstVisibleIndexPath = tableView.indexPathsForVisibleRows?.first else { return }

		let firstVisibleRowRect = tableView.rectForRow(at: firstVisibleIndexPath)
		guard tableView.convert(firstVisibleRowRect, to: nil).origin.y < tableView.safeAreaInsets.top - 20 else { return }

		// We only mark immediately after scrolling stops, not during, to prevent scroll hitching
		markAsReadOnScrollWorkItem?.cancel()
		markAsReadOnScrollWorkItem = DispatchWorkItem { [weak self] in
			defer {
				self?.markAsReadOnScrollStart = nil
				self?.markAsReadOnScrollEnd = nil
			}
			
			guard let start: Int = self?.markAsReadOnScrollStart,
				  let end: Int = self?.markAsReadOnScrollEnd ?? self?.markAsReadOnScrollStart,
				  start <= end,
				  let self = self else {
				return
			}
			
			let articles = Array(start...end)
				.map({ IndexPath(row: $0, section: 0) })
				.compactMap({ self.dataSource.itemIdentifier(for: $0) })
				.filter({ $0.status.read == false })
			self.coordinator.markAllAsRead(articles)
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: markAsReadOnScrollWorkItem!)

		// Here we are creating a range of rows to attempt to mark later with the work item
		guard markAsReadOnScrollStart != nil else {
			markAsReadOnScrollStart = max(firstVisibleIndexPath.row - 5, 0)
			return
		}
		markAsReadOnScrollEnd = max(markAsReadOnScrollEnd ?? 0, firstVisibleIndexPath.row)
	}
	
	func toggleArticleReadStatusAction(_ article: Article) -> UIAction? {
		guard !article.status.read || article.isAvailableToMarkUnread else { return nil }
		
		let title = article.status.read ?
		NSLocalizedString("button.title.mark-as-unread.titlecase", comment: "Mark as Unread. Used to mark an article unread") :
		NSLocalizedString("button.title.mark-as-read.titlecase", comment: "Mark as Read. Used to mark an article Read")
		let image = article.status.read ? AppAssets.circleClosedImage : AppAssets.circleOpenImage

		let action = UIAction(title: title, image: image) { [weak self] action in
			self?.coordinator.toggleRead(article)
		}
		
		return action
	}
	
	func toggleArticleStarStatusAction(_ article: Article) -> UIAction {

		let title = article.status.starred ?
		NSLocalizedString("button.title.mark-as-unstarred.titlecase", comment: "Mark as Unstarred. Used to mark an article as unstarred") :
		NSLocalizedString("button.title.mark-as-starred.titlecase", comment: "Mark as Starred. Used to mark an article as starred")
		let image = article.status.starred ? AppAssets.starOpenImage : AppAssets.starClosedImage

		let action = UIAction(title: title, image: image) { [weak self] action in
			self?.coordinator.toggleStar(article)
		}
		
		return action
	}

	func markAboveAsReadAction(_ article: Article, indexPath: IndexPath) -> UIAction? {
		guard coordinator.canMarkAboveAsRead(for: article), let contentView = self.tableView.cellForRow(at: indexPath)?.contentView else {
			return nil
		}
		
		let title = NSLocalizedString("button.title.mark-above-as-read.titlecase", comment: "Mark Above as Read. Used to mark articles above the current article as read.")
		let image = AppAssets.markAboveAsReadImage
		let action = UIAction(title: title, image: image) { [weak self] action in
			MarkAsReadAlertController.confirm(self, coordinator: self?.coordinator, confirmTitle: title, sourceType: contentView) { [weak self] in
				self?.coordinator.markAboveAsRead(article)
			}
		}
		return action
	}
	
	func markBelowAsReadAction(_ article: Article, indexPath: IndexPath) -> UIAction? {
		guard coordinator.canMarkBelowAsRead(for: article), let contentView = self.tableView.cellForRow(at: indexPath)?.contentView else {
			return nil
		}

		let title = NSLocalizedString("button.title.mark-below-as-read.titlecase", comment: "Mark Below as Read. Used to mark articles below the current article as read.")
		let image = AppAssets.markBelowAsReadImage
		let action = UIAction(title: title, image: image) { [weak self] action in
			MarkAsReadAlertController.confirm(self, coordinator: self?.coordinator, confirmTitle: title, sourceType: contentView) { [weak self] in
				self?.coordinator.markBelowAsRead(article)
			}
		}
		return action
	}
	
	func markAboveAsReadAlertAction(_ article: Article, indexPath: IndexPath, completion: @escaping (Bool) -> Void) -> UIAlertAction? {
		guard coordinator.canMarkAboveAsRead(for: article), let contentView = self.tableView.cellForRow(at: indexPath)?.contentView else {
			return nil
		}

		let title = NSLocalizedString("button.title.mark-above-as-read.titlecase", comment: "Mark Above as Read. Used to mark articles above the current article as read.")
		let cancel = {
			completion(true)
		}

		let action = UIAlertAction(title: title, style: .default) { [weak self] action in
			MarkAsReadAlertController.confirm(self, coordinator: self?.coordinator, confirmTitle: title, sourceType: contentView, cancelCompletion: cancel) { [weak self] in
				self?.coordinator.markAboveAsRead(article)
				completion(true)
			}
		}
		return action
	}

	func markBelowAsReadAlertAction(_ article: Article, indexPath: IndexPath, completion: @escaping (Bool) -> Void) -> UIAlertAction? {
		guard coordinator.canMarkBelowAsRead(for: article), let contentView = self.tableView.cellForRow(at: indexPath)?.contentView else {
			return nil
		}

		let title = NSLocalizedString("button.title.mark-below-as-read.titlecase", comment: "Mark Below as Read. Used to mark articles below the current article as read.")
		let cancel = {
			completion(true)
		}
		
		let action = UIAlertAction(title: title, style: .default) { [weak self] action in
			MarkAsReadAlertController.confirm(self, coordinator: self?.coordinator, confirmTitle: title, sourceType: contentView, cancelCompletion: cancel) { [weak self] in
				self?.coordinator.markBelowAsRead(article)
				completion(true)
			}
		}
		return action
	}
	
	func discloseFeedAction(_ article: Article) -> UIAction? {
		guard let feed = article.feed,
			!coordinator.timelineFeedIsEqualTo(feed) else { return nil }
		
		let title = NSLocalizedString("button.title.go-to-feed.titlecase", comment: "Go To Feed. Use to navigate to the user to the article list for a feed.")
		let action = UIAction(title: title, image: AppAssets.openInSidebarImage) { [weak self] action in
			self?.coordinator.discloseFeed(feed, animations: [.scroll, .navigation])
		}
		return action
	}
	
	func discloseFeedAlertAction(_ article: Article, completion: @escaping (Bool) -> Void) -> UIAlertAction? {
		guard let feed = article.feed,
			!coordinator.timelineFeedIsEqualTo(feed) else { return nil }

		let title = NSLocalizedString("button.title.go-to-feed", comment: "Go To Feed. Use to navigate to the user to the article list for a feed.")
		let action = UIAlertAction(title: title, style: .default) { [weak self] action in
			self?.coordinator.discloseFeed(feed, animations: [.scroll, .navigation])
			completion(true)
		}
		return action
	}
	
	func markAllInFeedAsReadAction(_ article: Article, indexPath: IndexPath) -> UIAction? {
		guard let feed = article.feed else { return nil }
		guard let fetchedArticles = try? feed.fetchArticles() else {
			return nil
		}

		let articles = Array(fetchedArticles)
		guard coordinator.canMarkAllAsRead(articles), let contentView = self.tableView.cellForRow(at: indexPath)?.contentView else {
			return nil
		}
		
		
		let localizedMenuText = NSLocalizedString("button.title.mark-all-as-read.%@", comment: "Mark All as Read in ”feed”. The variable name is the feed name.")
		let title = NSString.localizedStringWithFormat(localizedMenuText as NSString, feed.nameForDisplay) as String
		
		let action = UIAction(title: title, image: AppAssets.markAllAsReadImage) { [weak self] action in
			MarkAsReadAlertController.confirm(self, coordinator: self?.coordinator, confirmTitle: title, sourceType: contentView) { [weak self] in
				self?.coordinator.markAllAsRead(articles)
			}
		}
		return action
	}

	func markAllInFeedAsReadAlertAction(_ article: Article, indexPath: IndexPath, completion: @escaping (Bool) -> Void) -> UIAlertAction? {
		guard let feed = article.feed else { return nil }
		guard let fetchedArticles = try? feed.fetchArticles() else {
			return nil
		}
		
		let articles = Array(fetchedArticles)
		guard coordinator.canMarkAllAsRead(articles), let contentView = self.tableView.cellForRow(at: indexPath)?.contentView else {
			return nil
		}
		
		let localizedMenuText = NSLocalizedString("button.title.mark-all-as-read.%@", comment: "Mark All as Read in ”feed”. The variable name is the feed name.")
		let title = NSString.localizedStringWithFormat(localizedMenuText as NSString, feed.nameForDisplay) as String
		let cancel = {
			completion(true)
		}
		
		let action = UIAlertAction(title: title, style: .default) { [weak self] action in
			MarkAsReadAlertController.confirm(self, coordinator: self?.coordinator, confirmTitle: title, sourceType: contentView, cancelCompletion: cancel) { [weak self] in
				self?.coordinator.markAllAsRead(articles)
				completion(true)
			}
		}
		return action
	}
	
	func copyArticleURLAction(_ article: Article) -> UIAction? {
		guard let url = article.preferredURL else { return nil }
		let title = NSLocalizedString("button.title.copy-article-url", comment: "Copy Article URL")
		let action = UIAction(title: title, image: AppAssets.copyImage) { action in
			UIPasteboard.general.url = url
		}
		return action
	}
	
	func copyExternalURLAction(_ article: Article) -> UIAction? {
		guard let externalLink = article.externalLink, externalLink != article.preferredLink, let url = URL(string: externalLink) else { return nil }
		let title = NSLocalizedString("button.title.copy-external-url", comment: "Copy External URL")
		let action = UIAction(title: title, image: AppAssets.copyImage) { action in
			UIPasteboard.general.url = url
		}
		return action
	}


	func openInBrowserAction(_ article: Article) -> UIAction? {
		guard let _ = article.preferredURL else { return nil }
		let title = NSLocalizedString("button.title.open-in-browser", comment: "Open In Browser")
		let action = UIAction(title: title, image: AppAssets.safariImage) { [weak self] action in
			self?.coordinator.showBrowserForArticle(article)
		}
		return action
	}

	func openInBrowserAlertAction(_ article: Article, completion: @escaping (Bool) -> Void) -> UIAlertAction? {
		guard let _ = article.preferredURL else { return nil }

		let title = NSLocalizedString("button.title.open-in-browser", comment: "Open In Browser")
		let action = UIAlertAction(title: title, style: .default) { [weak self] action in
			self?.coordinator.showBrowserForArticle(article)
			completion(true)
		}
		return action
	}
	
	func shareDialogForTableCell(indexPath: IndexPath, url: URL, title: String?) {
		let activityViewController = UIActivityViewController(url: url, title: title, applicationActivities: nil)
		
		guard let cell = tableView.cellForRow(at: indexPath) else { return }
		let popoverController = activityViewController.popoverPresentationController
		popoverController?.sourceView = cell
		popoverController?.sourceRect = CGRect(x: 0, y: 0, width: cell.frame.size.width, height: cell.frame.size.height)
		
		present(activityViewController, animated: true)
	}
	
	func shareAction(_ article: Article, indexPath: IndexPath) -> UIAction? {
		guard let url = article.preferredURL else { return nil }
		let title = NSLocalizedString("button.title.share", comment: "Share")
		let action = UIAction(title: title, image: AppAssets.shareImage) { [weak self] action in
			self?.shareDialogForTableCell(indexPath: indexPath, url: url, title: article.title)
		}
		return action
	}
	
	func shareAlertAction(_ article: Article, indexPath: IndexPath, completion: @escaping (Bool) -> Void) -> UIAlertAction? {
		guard let url = article.preferredURL else { return nil }
		let title = NSLocalizedString("button.title.share", comment: "Share")
		let action = UIAlertAction(title: title, style: .default) { [weak self] action in
			completion(true)
			self?.shareDialogForTableCell(indexPath: indexPath, url: url, title: article.title)
		}
		return action
	}
	
}
