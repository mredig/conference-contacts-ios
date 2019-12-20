//
//  CoreDataStack.swift
//  swaap
//
//  Created by Michael Redig on 12/18/19.
//  Copyright © 2019 swaap. All rights reserved.
//

import Foundation
import CoreData

class CoreDataStack {
	static let shared = CoreDataStack()

	private init() {}

	/// A generic function to save any context we want (main or background)
	func save(context: NSManagedObjectContext) throws {
		//Placeholder in case something doesn't work
		var closureError: Error?

		context.performAndWait {
			do {
				try context.save()
			} catch {
				NSLog("error saving moc: \(error)")
				closureError = error
			}
		}
		if let error = closureError {
			throw error
		}
	}

	/// Access to the Persistent Container
	lazy var container: NSPersistentContainer = {
		let container = NSPersistentContainer(name: "Contacts")
		container.loadPersistentStores(completionHandler: { _, error in
			if let error = error {
				fatalError("Failed to load persistent store: \(error)")
			}
		})
		// May need to be disabled if dataset is too large for performance reasons
		container.viewContext.automaticallyMergesChangesFromParent = true
		return container
	}()

	var mainContext: NSManagedObjectContext {
		return container.viewContext
	}
}

extension NSManagedObjectContext {
	static let mainContext = CoreDataStack.shared.mainContext
}
