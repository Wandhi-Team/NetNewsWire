//
//  CloudKitArticlesZoneDelegate.swift
//  Account
//
//  Created by Maurice Parker on 4/1/20.
//  Copyright © 2020 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSCore
import RSParser
import RSWeb
import CloudKit
import SyncDatabase
import Articles
import ArticlesDatabase

class CloudKitArticlesZoneDelegate: CloudKitZoneDelegate, Logging {

	weak var account: Account?
	var database: SyncDatabase
	weak var articlesZone: CloudKitArticlesZone?
	var compressionQueue = DispatchQueue(label: "Articles Zone Delegate Compression Queue")
	
	init(account: Account, database: SyncDatabase, articlesZone: CloudKitArticlesZone) {
		self.account = account
		self.database = database
		self.articlesZone = articlesZone
	}
	
	func cloudKitWasChanged(updated: [CKRecord], deleted: [CloudKitRecordKey]) async throws {
		try await withCheckedThrowingContinuation { continuation in
			cloudKitWasChanged(updated: updated, deleted: deleted) { result in
				switch result {
				case .success:
					continuation.resume()
				case .failure(let error):
					continuation.resume(throwing: error)
				}
			}
		}
	}
}

private extension CloudKitArticlesZoneDelegate {

	func cloudKitWasChanged(updated: [CKRecord], deleted: [CloudKitRecordKey], completion: @escaping (Result<Void, Error>) -> Void) {

		Task { @MainActor in

			do {
				let pendingReadStatusArticleIDs = try await self.database.selectPendingReadArticleIDs()
				let pendingStarredStatusArticleIDs = try await self.database.selectPendingStarredArticleIDs()

				self.delete(recordKeys: deleted, pendingStarredStatusArticleIDs: pendingStarredStatusArticleIDs) { error in
					Task { @MainActor in
						if let error = error {
							completion(.failure(error))
						} else {
							self.update(records: updated,
										pendingReadStatusArticleIDs: pendingReadStatusArticleIDs,
										pendingStarredStatusArticleIDs: pendingStarredStatusArticleIDs,
										completion: completion)
						}
					}
				}
			} catch {
				self.logger.error("Error occurred getting pending read status records: \(error.localizedDescription, privacy: .public)")
				completion(.failure(CloudKitZoneError.unknown))
			}
		}
	}

	func delete(recordKeys: [CloudKitRecordKey], pendingStarredStatusArticleIDs: Set<String>, completion: @escaping (Error?) -> Void) {
		let receivedRecordIDs = recordKeys.filter({ $0.recordType == CloudKitArticlesZone.CloudKitArticleStatus.recordType }).map({ $0.recordID })
		let receivedArticleIDs = Set(receivedRecordIDs.map({ stripPrefix($0.externalID) }))
		let deletableArticleIDs = receivedArticleIDs.subtracting(pendingStarredStatusArticleIDs)
		
		guard !deletableArticleIDs.isEmpty else {
			completion(nil)
			return
		}

		Task { @MainActor in
			do {
				try await database.deleteSelectedForProcessing(Array(deletableArticleIDs))
				try await self.account?.deleteArticleIDs(deletableArticleIDs)
				completion(nil)
			} catch {
				completion(error)
			}
		}
	}

    @MainActor func update(records: [CKRecord], pendingReadStatusArticleIDs: Set<String>, pendingStarredStatusArticleIDs: Set<String>, completion: @escaping (Result<Void, Error>) -> Void) {

		let receivedUnreadArticleIDs = Set(records.filter({ $0[CloudKitArticlesZone.CloudKitArticleStatus.Fields.read] == "0" }).map({ stripPrefix($0.externalID) }))
		let receivedReadArticleIDs =  Set(records.filter({ $0[CloudKitArticlesZone.CloudKitArticleStatus.Fields.read] == "1" }).map({ stripPrefix($0.externalID) }))
		let receivedUnstarredArticleIDs =  Set(records.filter({ $0[CloudKitArticlesZone.CloudKitArticleStatus.Fields.starred] == "0" }).map({ stripPrefix($0.externalID) }))
		let receivedStarredArticleIDs =  Set(records.filter({ $0[CloudKitArticlesZone.CloudKitArticleStatus.Fields.starred] == "1" }).map({ stripPrefix($0.externalID) }))

		let updateableUnreadArticleIDs = receivedUnreadArticleIDs.subtracting(pendingReadStatusArticleIDs)
		let updateableReadArticleIDs = receivedReadArticleIDs.subtracting(pendingReadStatusArticleIDs)
		let updateableUnstarredArticleIDs = receivedUnstarredArticleIDs.subtracting(pendingStarredStatusArticleIDs)
		let updateableStarredArticleIDs = receivedStarredArticleIDs.subtracting(pendingStarredStatusArticleIDs)

		var errorOccurred = false
		let group = DispatchGroup()
		
		group.enter()
		account?.markAsUnread(updateableUnreadArticleIDs) { databaseError in
			if let databaseError = databaseError {
				errorOccurred = true
                self.logger.error("Error occurred while storing unread statuses: \(databaseError.localizedDescription, privacy: .public)")
			}
			group.leave()
		}
		
		group.enter()
		account?.markAsRead(updateableReadArticleIDs) { databaseError in
			if let databaseError = databaseError {
				errorOccurred = true
                self.logger.error("Error occurred while storing read statuses: \(databaseError.localizedDescription, privacy: .public)")
			}
			group.leave()
		}
		
		group.enter()
		account?.markAsUnstarred(updateableUnstarredArticleIDs) { databaseError in
			if let databaseError = databaseError {
				errorOccurred = true
                self.logger.error("Error occurred while storing unstarred statuses: \(databaseError.localizedDescription, privacy: .public)")
			}
			group.leave()
		}
		
		group.enter()
		account?.markAsStarred(updateableStarredArticleIDs) { databaseError in
			if let databaseError = databaseError {
				errorOccurred = true
                self.logger.error("Error occurred while storing starred records: \(databaseError.localizedDescription, privacy: .public)")
			}
			group.leave()
		}
		
		group.enter()
		compressionQueue.async {
			let parsedItems = records.compactMap { self.makeParsedItem($0) }
			let feedIDsAndItems = Dictionary(grouping: parsedItems, by: { item in item.feedURL } ).mapValues { Set($0) }
			
			Task { @MainActor in
				for (feedID, parsedItems) in feedIDsAndItems {
					group.enter()
					self.account?.update(feedID, with: parsedItems, deleteOlder: false) { result in
						Task { @MainActor in
							switch result {
							case .success(let articleChanges):
								guard let deletes = articleChanges.deletedArticles, !deletes.isEmpty else {
									group.leave()
									return
								}
								let syncStatuses = deletes.map { SyncStatus(articleID: $0.articleID, key: .deleted, flag: true) }
								try? await self.database.insertStatuses(syncStatuses)
								group.leave()
							case .failure(let databaseError):
								errorOccurred = true
								self.logger.error("Error occurred while storing articles: \(databaseError.localizedDescription, privacy: .public)")
								group.leave()
							}
						}
					}
				}
				group.leave()
			}
		}
		
		group.notify(queue: DispatchQueue.main) {
			if errorOccurred {
				completion(.failure(CloudKitZoneError.unknown))
			} else {
				completion(.success(()))
			}
		}
	}
	
	func stripPrefix(_ externalID: String) -> String {
		return String(externalID[externalID.index(externalID.startIndex, offsetBy: 2)..<externalID.endIndex])
	}

	func makeParsedItem(_ articleRecord: CKRecord) -> ParsedItem? {
		guard articleRecord.recordType == CloudKitArticlesZone.CloudKitArticle.recordType else {
			return nil
		}
		
		var parsedAuthors = Set<ParsedAuthor>()
		
		let decoder = JSONDecoder()
		
		if let encodedParsedAuthors = articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.parsedAuthors] as? [String] {
			for encodedParsedAuthor in encodedParsedAuthors {
				if let data = encodedParsedAuthor.data(using: .utf8), let parsedAuthor = try? decoder.decode(ParsedAuthor.self, from: data) {
					parsedAuthors.insert(parsedAuthor)
				}
			}
		}
		
		guard let uniqueID = articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.uniqueID] as? String,
			let feedURL = articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.feedURL] as? String else {
			return nil
		}
		
		var contentHTML = articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.contentHTML] as? String
		if let contentHTMLData = articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.contentHTMLData] as? NSData {
			if let decompressedContentHTMLData = try? contentHTMLData.decompressed(using: .lzfse) {
				contentHTML = String(data: decompressedContentHTMLData as Data, encoding: .utf8)
			}
		}
		
		var contentText = articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.contentText] as? String
		if let contentTextData = articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.contentTextData] as? NSData {
			if let decompressedContentTextData = try? contentTextData.decompressed(using: .lzfse) {
				contentText = String(data: decompressedContentTextData as Data, encoding: .utf8)
			}
		}
		
		let parsedItem = ParsedItem(syncServiceID: nil,
									uniqueID: uniqueID,
									feedURL: feedURL,
									url: articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.url] as? String,
									externalURL: articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.externalURL] as? String,
									title: articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.title] as? String,
									language: nil,
									contentHTML: contentHTML,
									contentText: contentText,
									summary: articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.summary] as? String,
									imageURL: articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.imageURL] as? String,
									bannerImageURL: articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.imageURL] as? String,
									datePublished: articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.datePublished] as? Date,
									dateModified: articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.dateModified] as? Date,
									authors: parsedAuthors,
									tags: nil,
									attachments: nil)
		
		return parsedItem
	}
	
}
