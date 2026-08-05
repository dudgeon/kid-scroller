import SwiftUI
import ContactsUI
import Contacts

/// Prefills a birthday from a Contacts card (R9).
///
/// Uses `CNContactPickerViewController`, which runs out of process — the user picks the
/// card in Apple's own UI and only that one contact comes back, so the app never needs
/// full Contacts authorization and never sees the rest of the address book.
///
/// PhotoKit does not expose the birthdays shown in the Photos app's People view, so this
/// is the only automatic source available; manual entry remains the fallback everywhere.
struct ContactBirthdayPicker: UIViewControllerRepresentable {
    let onPick: (Date) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let controller = CNContactPickerViewController()
        controller.delegate = context.coordinator
        // Only offer cards that actually carry a birthday.
        controller.predicateForEnablingContact = NSPredicate(format: "birthday != nil")
        controller.displayedPropertyKeys = [CNContactBirthdayKey]
        return controller
    }

    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        private let onPick: (Date) -> Void
        init(onPick: @escaping (Date) -> Void) { self.onPick = onPick }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            guard var components = contact.birthday else { return }
            // Contacts allows a birthday with no year; without one there is no age axis,
            // so leave it for the user to enter rather than inventing a year.
            guard components.year != nil else { return }
            components.calendar = Calendar.current
            if let date = components.date { onPick(date) }
        }
    }
}
