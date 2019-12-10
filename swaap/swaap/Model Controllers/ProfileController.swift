//
//  ProfileController.swift
//  swaap
//
//  Created by Michael Redig on 12/5/19.
//  Copyright © 2019 swaap. All rights reserved.
//

import Foundation
import NetworkHandler

protocol ProfileAccessor: AnyObject {
	var profileController: ProfileController? { get set }
}

class ProfileController {
	let authManager: AuthManager

	private var _userProfile: UserProfile?
	/// Automatically sends `userProfileChanged`, `userProfilePopulated`, or `userProfileDepopulated` notifications when modified
	var userProfile: UserProfile? {
		get { _userProfile }
		set {
			let oldValue = _userProfile
			_userProfile = newValue
			checkUserProfileChanged(oldValue: oldValue, newValue: newValue)
		}
	}

	let baseURL = URL(string: "https://lambda-labs-swaap-staging.herokuapp.com/")!
	var graphqlURL: URL {
		baseURL.appendingPathComponent("graphql")
	}
	let networkHandler: NetworkHandler = {
		let networkHandler = NetworkHandler()
		networkHandler.graphQLErrorSupport = true
		return networkHandler
	}()

	private var depopCredentialObserver: NSObjectProtocol?
	private var restoredCredentialObserver: NSObjectProtocol?

	// MARK: - Lifecycle
	init(authManager: AuthManager) {
		self.authManager = authManager
		depopCredentialObserver = NotificationCenter.default.addObserver(forName: .swaapCredentialsDepopulated, object: nil, queue: nil, using: { _ in
			self.userProfile = nil
		})
		// theoretically, this should run before the credentials are restored, (but it doesnt) and the following code should not be populated (but it is), so I'm not sure how to proceed
//		restoredCredentialObserver = NotificationCenter.default.addObserver(forName: .swaapCredentialsRestored, object: nil, queue: nil, using: { _ in
//			self.fetchProfileFromServer { (result: Result<UserProfile, NetworkError>) in
//				do {
//					let user = try result.get()
//					print(user)
//				} catch {
//					NSLog("Error getting user: \(error)")
//				}
//			}
//		})
		if authManager.credentials != nil {
			self.fetchProfileFromServer { (result: Result<UserProfile, NetworkError>) in
				do {
					let user = try result.get()
					print(user)
				} catch {
					NSLog("Error getting user: \(error)")
				}
			}
		}
	}

	// MARK: - Networking
	func createProfileOnServer(completion: ((Bool) -> Void)? = nil) {
		guard let (idClaims, cRequest) = networkCommon() else {
			completion?(false)
			return
		}
		var request = cRequest

		let mutation = "mutation CreateUser($user: CreateUserInput!) { createUser(data: $user) { success code message } }"
		let userInfo = ["user": CreateUser(name: idClaims.name, picture: idClaims.picture, email: idClaims.email)]

		let graphObject = GQMutation(query: mutation, variables: userInfo)

		do {
			request.httpBody = try JSONEncoder().encode(graphObject)
		} catch {
			NSLog("Failed encoding graph object: \(error)")
			completion?(false)
			return
		}

		request.expectedResponseCodes = 200
		networkHandler.transferMahCodableDatas(with: request) { (result: Result<UserMutationResponseContainer, NetworkError>) in
			do {
				let responseContainer = try result.get()
				let response = responseContainer.response
				completion?(response.success)
			} catch NetworkError.httpNon200StatusCode(let code, let data) {
				NSLog("Error creating server profile with code: \(code): \(String(data: data!, encoding: .utf8)!)")
				completion?(false)
			} catch {
				NSLog("Error creating server profile: \(error)")
				completion?(false)
			}
		}
	}

	func fetchProfileFromServer(completion: @escaping (Result<UserProfile, NetworkError>) -> Void) {
		guard var (_, request) = networkCommon() else {
			completion(.failure(NetworkError.unspecifiedError(reason: "Either claims or request were not attainable.")))
			return
		}
		// while networking, load from disk if same user
		loadCachedProfile()

		let query = "{ user { id authId name picture birthdate gender industry jobtitle bio profile { id value type privacy preferredContact } } }"
		let graphObject = GQuery(query: query)

		do {
			request.httpBody = try JSONEncoder().encode(graphObject)
		} catch {
			NSLog("Failed encoding graph object: \(error)")
			completion(.failure(.dataCodingError(specifically: error, sourceData: nil)))
			return
		}

		request.expectedResponseCodes = [200]

		networkHandler.transferMahCodableDatas(with: request) { (result: Result<UserProfileContainer, NetworkError>) in
			do {
				let userProfileContainer = try result.get()
				let userProfile = userProfileContainer.userProfile
				self.userProfile = userProfile
				completion(.success(userProfile))
			} catch NetworkError.dataCodingError(let error, let dataSource) {
				print("")
				NSLog("Error decoding current user: \(error)")
				print("")
				print(String(data: dataSource ?? Data(), encoding: .utf8) ?? "")
				print("")
			} catch NetworkError.graphQLError(let graphQLError) {
				// only attempt creation if error code relating to user not existing ocurrs
				// I don't know if its guaranteed to be consistent that no user existing will always have an error like this
				// but it's the best we got right now
				if graphQLError.message.contains("'authId' of null") && graphQLError.extensions.code == "INTERNAL_SERVER_ERROR" {
					self.createProfileOnServer { success in
						if success {
							self.fetchProfileFromServer(completion: completion)
						} else {
							completion(.failure(NetworkError.graphQLError(error: graphQLError)))
							print("")
							NSLog("Error fetching current user \(#line) \(#file): \(graphQLError)")
						}
					}
				} else {
					NSLog("Error fetching current user \(#line) \(#file): \(graphQLError)")
				}
			} catch {
				// attempt user creation if fetching fails
				NSLog("Error fetching current user \(#line) \(#file): \(error)")
			}
		}
	}

	private func networkCommon() -> (Auth0IDClaims, NetworkRequest)? {
		guard let idClaims = authManager.idClaims, let accessToken = authManager.credentials?.accessToken else { return nil }
		var request = graphqlURL.request
		request.addValue(.contentType(type: .json), forHTTPHeaderField: .commonKey(key: .contentType))
		request.addValue(.other(value: accessToken), forHTTPHeaderField: .commonKey(key: .authorization))
		request.httpMethod = .post
		return (idClaims, request)
	}

	func fetchImage(url: URL, completion: @escaping (Result<Data, NetworkError>) -> Void) {
		networkHandler.transferMahDatas(with: url.request, usingCache: true, completion: completion)
	}

	/// By default, only updates if photo is nil. `force` will force it to download, even if there's already data.
	/// - Parameter force: Bool determining if the update is forced or contextual.
	func updateUserImage(_ force: Bool = false) {
		guard let userProfile = userProfile, (force || userProfile.photoData == nil) else { return }
		fetchImage(url: userProfile.pictureURL) { (result: Result<Data, NetworkError>) in
			do {
				self.userProfile?.photoData = try result.get()
			} catch {
				NSLog("Error loading user profile image: \(error)")
			}
		}
	}

	// MARK: - Local Storage
	private let fm = FileManager.default
	private let profileCacheFilename = "profile.plist"
	private var profileCacheURL: URL {
		guard let cacheFolder = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { preconditionFailure("Something catastophically wrong occurred...") }
		return cacheFolder.appendingPathComponent(profileCacheFilename)
	}

	private func loadCachedProfile() {
		// note - doesn't trigger populate notification on startup because it happens before the observer is initialized
		guard fm.fileExists(atPath: profileCacheURL.path), let claims = authManager.idClaims else { return }
		let data: Data
		do {
			data = try Data(contentsOf: profileCacheURL)
		} catch {
			NSLog("Error loading cached profile data: \(error)")
			return
		}

		do {
			let userProfile = try PropertyListDecoder().decode(UserProfile.self, from: data)
			if userProfile.authID == claims.authID {
				self.userProfile = userProfile
			}
		} catch {
			NSLog("Error decoding cached profile data: \(error)")
		}
	}

	private func saveProfileToCache() {
		guard let profile = userProfile else {
			deleteProfileCache()
			return
		}

		let data: Data
		do {
			data = try PropertyListEncoder().encode(profile)
		} catch {
			NSLog("Error encoding profile cache: \(error)")
			return
		}

		do {
			try data.write(to: profileCacheURL)
		} catch {
			NSLog("Error saving profile cache: \(error)")
		}
	}

	private func deleteProfileCache() {
		do {
			try fm.removeItem(at: profileCacheURL)
		} catch {
			NSLog("Error deleting profile cache: \(error)")
		}
	}
}

// MARK: - Notifications
extension ProfileController {
	private func checkUserProfileChanged(oldValue: UserProfile?, newValue: UserProfile?) {
		guard oldValue != newValue else { return }
		let nc = NotificationCenter.default
		if oldValue == nil {
			nc.post(name: .userProfilePopulated, object: nil)
		} else if newValue == nil {
			nc.post(name: .userProfileDepopulated, object: nil)
		} else {
			nc.post(name: .userProfileChanged, object: nil)
		}
		updateUserImage()
		saveProfileToCache()
	}
}

extension NSNotification.Name {
	static let userProfileChanged = NSNotification.Name("com.swaap.userProfileChanged")
	static let userProfilePopulated = NSNotification.Name("com.swaap.userProfilePopulated")
	static let userProfileDepopulated = NSNotification.Name("com.swaap.userProfileDepopulated")
}
