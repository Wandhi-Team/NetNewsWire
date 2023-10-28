//
//  AccountDelegate.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 9/16/17.
//  Copyright © 2017 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import Articles
import RSWeb
import Secrets

@MainActor protocol AccountDelegate {

	var behaviors: AccountBehaviors { get }

	var isOPMLImportInProgress: Bool { get }
	
	var server: String? { get }
	var credentials: Credentials? { get set }
	var accountMetadata: AccountMetadata? { get set }
	
	var refreshProgress: DownloadProgress { get }

	func receiveRemoteNotification(for account: Account, userInfo: [AnyHashable : Any]) async

	func refreshAll(for account: Account) async throws
	func syncArticleStatus(for account: Account) async throws
	func sendArticleStatus(for account: Account, completion: @escaping ((Result<Void, Error>) -> Void))
	func refreshArticleStatus(for account: Account, completion: @escaping ((Result<Void, Error>) -> Void))
	
	func importOPML(for account:Account, opmlFile: URL, completion: @escaping (Result<Void, Error>) -> Void)
	
	func createFolder(for account: Account, name: String) async throws -> Folder
	func renameFolder(for account: Account, with folder: Folder, to name: String) async throws
	func removeFolder(for account: Account, with folder: Folder) async throws

	func createFeed(for account: Account, url: String, name: String?, container: Container, validateFeed: Bool, completion: @escaping (Result<Feed, Error>) -> Void)
    func renameFeed(for account: Account, feed: Feed, name: String) async throws
	func addFeed(for account: Account, with: Feed, to container: Container, completion: @escaping (Result<Void, Error>) -> Void)
	func removeFeed(for account: Account, with feed: Feed, from container: Container, completion: @escaping (Result<Void, Error>) -> Void)
	func moveFeed(for account: Account, with feed: Feed, from: Container, to: Container, completion: @escaping (Result<Void, Error>) -> Void)

	func restoreFeed(for account: Account, feed: Feed, container: Container, completion: @escaping (Result<Void, Error>) -> Void)
	func restoreFolder(for account: Account, folder: Folder, completion: @escaping (Result<Void, Error>) -> Void)

	func markArticles(for account: Account, articles: Set<Article>, statusKey: ArticleStatus.Key, flag: Bool, completion: @escaping (Result<Void, Error>) -> Void)

	// Called at the end of account’s init method.
	func accountDidInitialize(_ account: Account)
	
	func accountWillBeDeleted(_ account: Account)

	static func validateCredentials(transport: Transport, credentials: Credentials, endpoint: URL?) async throws -> Credentials?

	/// Suspend all network activity
	func suspendNetwork()
	
	/// Suspend the SQLite databases
	func suspendDatabase()
	
	/// Make sure no SQLite databases are open and we are ready to issue network requests.
	func resume()
}
