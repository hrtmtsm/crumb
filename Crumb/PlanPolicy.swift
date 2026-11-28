import Foundation

/// One policy shared by UI actions and save guards. Server RPCs independently enforce the same rules.
enum PlanPolicy {
    static func canEdit(book: MenuBook, viewer: UUID?, plus: Bool) -> Bool {
        if let owner = book.ownerID, owner != viewer { return book.ownerHasPlus == true }
        return book.id == MenuBook.defaultID || plus
    }
    static func canInvite(book: MenuBook, viewer: UUID?, plus: Bool) -> Bool {
        guard viewer != nil, plus else { return false }
        return book.ownerID == nil || book.ownerID == viewer
    }
    static func canCreateOwnedBook(plus: Bool) -> Bool { plus }
    // An invited book never consumes the user's one free personal menu.
    static func isOwned(_ book: MenuBook, viewer: UUID?) -> Bool {
        book.ownerID == nil || book.ownerID == viewer
    }
}

extension Notification.Name {
    static let crumbLibraryChanged = Notification.Name("crumb.library.changed")
}
