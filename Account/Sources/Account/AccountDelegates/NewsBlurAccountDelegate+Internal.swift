//
//  NewsBlurAccountDelegate+Internal.swift
//  Mostly adapted from FeedbinAccountDelegate.swift
//  Account
//
//  Created by Anh Quang Do on 2020-03-14.
//  Copyright (c) 2020 Ranchero Software, LLC. All rights reserved.
//

import Articles
import RSCore
import RSDatabase
import RSParser
import RSWeb
import SyncDatabase
import NewsBlur
import AccountError

extension NewsBlurAccountDelegate {
	
	func refreshFeeds(for account: Account, completion: @escaping (Result<Void, Error>) -> Void) {
        logger.debug("Refreshing feeds...")
        

		caller.retrieveFeeds { result in
			switch result {
			case .success((let feeds, let folders)):
				BatchUpdate.shared.perform {
					self.syncFolders(account, folders)
					self.syncFeeds(account, feeds)
					self.syncFeedFolderRelationship(account, folders)
				}
				completion(.success(()))
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	func syncFolders(_ account: Account, _ folders: [NewsBlurFolder]?) {
		guard let folders = folders else { return }
		assert(Thread.isMainThread)

        logger.debug("Syncing folders with \(folders.count, privacy: .public) folders.")

		let folderNames = folders.map { $0.name }

		// Delete any folders not at NewsBlur
		if let folders = account.folders {
            for folder in folders {
				if !folderNames.contains(folder.name ?? "") {
					for feed in folder.topLevelFeeds {
						account.addFeed(feed)
						clearFolderRelationship(for: feed, withFolderName: folder.name ?? "")
					}
					account.removeFolder(folder)
				}
			}
		}

		let accountFolderNames: [String] =  {
			if let folders = account.folders {
				return folders.map { $0.name ?? "" }
			} else {
				return [String]()
			}
		}()

		// Make any folders NewsBlur has, but we don't
		// Ignore account-level folder
        for folderName in folderNames {
			if !accountFolderNames.contains(folderName) && folderName != " " {
				_ = account.ensureFolder(with: folderName)
			}
		}
	}

	func syncFeeds(_ account: Account, _ feeds: [NewsBlurFeed]?) {
		guard let feeds = feeds else { return }
		assert(Thread.isMainThread)

        logger.debug("Syncing feeds with \(feeds.count, privacy: .public) feeds.")

		let newsBlurFeedIDs = feeds.map { String($0.feedID) }

		// Remove any feeds that are no longer in the subscriptions
		if let folders = account.folders {
			for folder in folders {
				for feed in folder.topLevelFeeds {
					if !newsBlurFeedIDs.contains(feed.feedID) {
						folder.removeFeed(feed)
					}
				}
			}
		}

		for feed in account.topLevelFeeds {
			if !newsBlurFeedIDs.contains(feed.feedID) {
				account.removeFeed(feed)
			}
		}

		// Add any feeds we don't have and update any we do
		var feedsToAdd = Set<NewsBlurFeed>()
		for newsBlurFeed in feeds {
			let subFeedID = String(newsBlurFeed.feedID)

			if let feed = account.existingFeed(withFeedID: subFeedID) {
				feed.name = newsBlurFeed.name
				// If the name has been changed on the server remove the locally edited name
                feed.editedName = nil
                feed.homePageURL = newsBlurFeed.homePageURL
                feed.externalID = String(newsBlurFeed.feedID)
                feed.faviconURL = newsBlurFeed.faviconURL
			}
			else {
				feedsToAdd.insert(newsBlurFeed)
			}
		}

		// Actually add feeds all in one go, so we don’t trigger various rebuilding things that Account does.
        for newsBlurFeed in feedsToAdd {
			let feed = account.createFeed(with: newsBlurFeed.name, url: newsBlurFeed.feedURL, feedID: String(newsBlurFeed.feedID), homePageURL: newsBlurFeed.homePageURL)
            feed.externalID = String(newsBlurFeed.feedID)
			account.addFeed(feed)
		}
	}

	func syncFeedFolderRelationship(_ account: Account, _ folders: [NewsBlurFolder]?) {
		guard let folders = folders else { return }
		assert(Thread.isMainThread)

        logger.debug("Syncing folders with \(folders.count, privacy: .public) folders.")

		// Set up some structures to make syncing easier
		let relationships = folders.map({ $0.asRelationships }).flatMap { $0 }
		let folderDict = nameToFolderDictionary(with: account.folders)
		let newsBlurFolderDict = relationships.reduce([String: [NewsBlurFolderRelationship]]()) { (dict, relationship) in
			var feedInFolders = dict
			if var feedInFolder = feedInFolders[relationship.folderName] {
				feedInFolder.append(relationship)
				feedInFolders[relationship.folderName] = feedInFolder
			} else {
				feedInFolders[relationship.folderName] = [relationship]
			}
			return feedInFolders
		}

		// Sync the folders
		for (folderName, folderRelationships) in newsBlurFolderDict {
			guard folderName != " " else {
				continue
			}

			let newsBlurFolderFeedIDs = folderRelationships.map { String($0.feedID) }

			guard let folder = folderDict[folderName] else { return }

			// Move any feeds not in the folder to the account
			for feed in folder.topLevelFeeds {
				if !newsBlurFolderFeedIDs.contains(feed.feedID) {
					folder.removeFeed(feed)
					clearFolderRelationship(for: feed, withFolderName: folder.name ?? "")
					account.addFeed(feed)
				}
			}

			// Add any feeds not in the folder
			let folderFeedIDs = folder.topLevelFeeds.map { $0.feedID }

			for relationship in folderRelationships {
				let folderFeedID = String(relationship.feedID)
				if !folderFeedIDs.contains(folderFeedID) {
					guard let feed = account.existingFeed(withFeedID: folderFeedID) else {
						continue
					}
					saveFolderRelationship(for: feed, withFolderName: folderName, id: relationship.folderName)
					folder.addFeed(feed)
				}
			}
		}
		
		// Handle the account level feeds.  If there isn't the special folder, that means all the feeds are
		// in folders and we need to remove them all from the account level.
		if let folderRelationships = newsBlurFolderDict[" "] {
			let newsBlurFolderFeedIDs = folderRelationships.map { String($0.feedID) }
			for feed in account.topLevelFeeds {
				if !newsBlurFolderFeedIDs.contains(feed.feedID) {
					account.removeFeed(feed)
				}
			}
		} else {
			for feed in account.topLevelFeeds {
				account.removeFeed(feed)
			}
		}
		
	}

	func clearFolderRelationship(for feed: Feed, withFolderName folderName: String) {
		if var folderRelationship = feed.folderRelationship {
			folderRelationship[folderName] = nil
			feed.folderRelationship = folderRelationship
		}
	}

	func saveFolderRelationship(for feed: Feed, withFolderName folderName: String, id: String) {
		if var folderRelationship = feed.folderRelationship {
			folderRelationship[folderName] = id
			feed.folderRelationship = folderRelationship
		} else {
			feed.folderRelationship = [folderName: id]
		}
	}

	func nameToFolderDictionary(with folders: Set<Folder>?) -> [String: Folder] {
		guard let folders = folders else {
			return [String: Folder]()
		}

		var d = [String: Folder]()
		for folder in folders {
			let name = folder.name ?? ""
			if d[name] == nil {
				d[name] = folder
			}
		}
		return d
	}

	func refreshUnreadStories(for account: Account, hashes: [NewsBlurStoryHash]?, updateFetchDate: Date?, completion: @escaping (Result<Void, Error>) -> Void) {
		guard let hashes = hashes, !hashes.isEmpty else {
			if let lastArticleFetch = updateFetchDate {
				self.accountMetadata?.lastArticleFetchStartTime = lastArticleFetch
				self.accountMetadata?.lastArticleFetchEndTime = Date()
			}
			completion(.success(()))
			return
		}

		let numberOfStories = min(hashes.count, 100) // api limit
		let hashesToFetch = Array(hashes[..<numberOfStories])

		caller.retrieveStories(hashes: hashesToFetch) { result in
			switch result {
			case .success((let stories, let date)):
				self.processStories(account: account, stories: stories) { result in
					self.refreshProgress.completeTask()

					if case .failure(let error) = result {
						completion(.failure(error))
						return
					}

					self.refreshUnreadStories(for: account, hashes: Array(hashes[numberOfStories...]), updateFetchDate: date) { result in
                        self.logger.debug("Done refreshing stories.")
						switch result {
						case .success:
							completion(.success(()))
						case .failure(let error):
							completion(.failure(error))
						}
					}
				}
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	func mapStoriesToParsedItems(stories: [NewsBlurStory]?) -> Set<ParsedItem> {
		guard let stories = stories else { return Set<ParsedItem>() }

		let parsedItems: [ParsedItem] = stories.map { story in
			let author = Set([ParsedAuthor(name: story.authorName, url: nil, avatarURL: nil, emailAddress: nil)])
			return ParsedItem(syncServiceID: story.storyID, uniqueID: String(story.storyID), feedURL: String(story.feedID), url: story.url, externalURL: nil, title: story.title, language: nil, contentHTML: story.contentHTML, contentText: nil, summary: nil, imageURL: story.imageURL, bannerImageURL: nil, datePublished: story.datePublished, dateModified: nil, authors: author, tags: Set(story.tags ?? []), attachments: nil)
		}

		return Set(parsedItems)
	}

	func sendStoryStatuses(_ statuses: [SyncStatus],
								   throttle: Bool,
								   apiCall: ([String], @escaping (Result<Void, Error>) -> Void) -> Void,
								   completion: @escaping (Result<Void, Error>) -> Void) {
		guard !statuses.isEmpty else {
			completion(.success(()))
			return
		}

		let group = DispatchGroup()
		var errorOccurred = false

		let storyHashes = statuses.compactMap { $0.articleID }
		let storyHashGroups = storyHashes.chunked(into: throttle ? 1 : 5) // api limit
		for storyHashGroup in storyHashGroups {
			group.enter()
			apiCall(storyHashGroup) { result in
				Task { @MainActor in
					let articleIDs = storyHashGroup.map { String($0) }
					switch result {
					case .success:
						do {
							try await self.database.deleteSelectedForProcessing(articleIDs)
							group.leave()
						} catch {
							errorOccurred = true
							self.logger.error("Story status sync call failed: \(error.localizedDescription, privacy: .public)")
							try? await self.database.resetSelectedForProcessing(articleIDs)
							group.leave()
						}
					case .failure(let error):
						errorOccurred = true
						self.logger.error("Story status sync call failed: \(error.localizedDescription, privacy: .public)")
						try? await self.database.resetSelectedForProcessing(articleIDs)
						group.leave()
					}
				}
			}
		}

		group.notify(queue: DispatchQueue.main) {
			if errorOccurred {
				completion(.failure(NewsBlurError.unknown))
			} else {
				completion(.success(()))
			}
		}
	}

    func syncStoryReadState(account: Account, hashes: [NewsBlurStoryHash]?, completion: @escaping (() -> Void)) {

        Task { @MainActor in
            guard let hashes = hashes else {
                completion()
                return
            }

            do {
                let pendingStoryHashes = try await database.selectPendingReadArticleIDs()

                let newsBlurUnreadStoryHashes = Set(hashes.map { $0.hash } )
                let updatableNewsBlurUnreadStoryHashes = newsBlurUnreadStoryHashes.subtracting(pendingStoryHashes)

                let currentUnreadArticleIDs = try await account.fetchUnreadArticleIDs()
                
                // Mark articles as unread
                let deltaUnreadArticleIDs = updatableNewsBlurUnreadStoryHashes.subtracting(currentUnreadArticleIDs)
                try await account.markArticleIDsAsUnread(deltaUnreadArticleIDs)

                // Mark articles as read
                let deltaReadArticleIDs = currentUnreadArticleIDs.subtracting(updatableNewsBlurUnreadStoryHashes)
                try await account.markArticleIDsAsRead(deltaReadArticleIDs)
            } catch let error {
                self.logger.error("Sync story read status failed: \(error.localizedDescription, privacy: .public)")
            }

            completion()
        }
    }

    func syncStoryStarredState(account: Account, hashes: [NewsBlurStoryHash]?, completion: @escaping (() -> Void)) {

        Task { @MainActor in
            guard let hashes = hashes else {
                completion()
                return
            }

            do {
                let pendingStoryHashes = try await database.selectPendingStarredArticleIDs()

                let newsBlurStarredStoryHashes = Set(hashes.map { $0.hash } )
                let updatableNewsBlurUnreadStoryHashes = newsBlurStarredStoryHashes.subtracting(pendingStoryHashes)

                let currentStarredArticleIDs = try await account.fetchStarredArticleIDs()

                // Mark articles as starred
                let deltaStarredArticleIDs = updatableNewsBlurUnreadStoryHashes.subtracting(currentStarredArticleIDs)
                account.markAsStarred(deltaStarredArticleIDs)

                // Mark articles as unstarred
                let deltaUnstarredArticleIDs = currentStarredArticleIDs.subtracting(updatableNewsBlurUnreadStoryHashes)
                account.markAsUnstarred(deltaUnstarredArticleIDs)
            } catch let error {
                self.logger.error("Sync story starred status failed: \(error.localizedDescription, privacy: .public)")
            }

            completion()
        }
    }

	func createFeed(account: Account, newsBlurFeed: NewsBlurFeed?, name: String?, container: Container, completion: @escaping (Result<Feed, Error>) -> Void) {
		guard let newsBlurFeed = newsBlurFeed else {
			completion(.failure(NewsBlurError.invalidParameter))
			return
		}
		
		DispatchQueue.main.async {
			let feed = account.createFeed(with: newsBlurFeed.name, url: newsBlurFeed.feedURL, feedID: String(newsBlurFeed.feedID), homePageURL: newsBlurFeed.homePageURL)
			feed.externalID = String(newsBlurFeed.feedID)
			feed.faviconURL = newsBlurFeed.faviconURL
			
			account.addFeed(feed, to: container) { result in
				
				Task { @MainActor in
					switch result {
					case .success:
						if let name {
							do {
								try await account.rename(feed, to: name)
								self.initialFeedDownload(account: account, feed: feed, completion: completion)
							} catch {
								completion(.failure(error))
							}
						}
						else {
							self.initialFeedDownload(account: account, feed: feed, completion: completion)
						}
					case .failure(let error):
						completion(.failure(error))
					}
				}
			}
		}
	}

	func downloadFeed(account: Account, feed: Feed, page: Int, completion: @escaping (Result<Void, Error>) -> Void) {
		refreshProgress.addToNumberOfTasksAndRemaining(1)

		caller.retrieveStories(feedID: feed.feedID, page: page) { result in
			switch result {
			case .success((let stories, _)):
				// No more stories
				guard let stories = stories, stories.count > 0 else {
					self.refreshProgress.completeTask()

					completion(.success(()))
					return
				}

				let since: Date? = Calendar.current.date(byAdding: .month, value: -3, to: Date())

				self.processStories(account: account, stories: stories, since: since) { result in
					self.refreshProgress.completeTask()

					if case .failure(let error) = result {
						completion(.failure(error))
						return
					}

					// No more recent stories
					if case .success(let hasStories) = result, !hasStories {
						completion(.success(()))
						return
					}
					
					self.downloadFeed(account: account, feed: feed, page: page + 1, completion: completion)
				}

			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	func initialFeedDownload(account: Account, feed: Feed, completion: @escaping (Result<Feed, Error>) -> Void) {
		refreshProgress.addToNumberOfTasksAndRemaining(1)

		// Download the initial articles
		downloadFeed(account: account, feed: feed, page: 1) { result in
			Task { @MainActor in
				do {
					try await self.refreshArticleStatus(for: account)
					self.refreshMissingStories(for: account) { result in
						switch result {
						case .success:
							self.refreshProgress.completeTask()

							DispatchQueue.main.async {
								completion(.success(feed))
							}

						case .failure(let error):
							completion(.failure(error))
						}
					}
				} catch {
					completion(.failure(error))
				}
			}
		}
	}

	func deleteFeed(for account: Account, with feed: Feed, from container: Container?, completion: @escaping (Result<Void, Error>) -> Void) {
		// This error should never happen
		guard let feedID = feed.externalID else {
			completion(.failure(NewsBlurError.invalidParameter))
			return
		}

		refreshProgress.addToNumberOfTasksAndRemaining(1)

		let folderName = (container as? Folder)?.name
		caller.deleteFeed(feedID: feedID, folder: folderName) { result in
			self.refreshProgress.completeTask()

			switch result {
			case .success:
				DispatchQueue.main.async {
					let feedID = feed.feedID

					if folderName == nil {
						account.removeFeed(feed)
					}

					if let folders = account.folders {
						for folder in folders where folderName != nil && folder.name == folderName {
							folder.removeFeed(feed)
						}
					}

					if account.existingFeed(withFeedID: feedID) != nil {
						account.clearFeedMetadata(feed)
					}

					completion(.success(()))
				}

			case .failure(let error):
				DispatchQueue.main.async {
					let wrappedError = WrappedAccountError(accountID: account.accountID, accountNameForDisplay: account.nameForDisplay, underlyingError: error)
					completion(.failure(wrappedError))
				}
			}
		}
	}
}
