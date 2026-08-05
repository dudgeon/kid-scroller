import Foundation

/// Conversion between wall-clock dates and the app's continuous age axis.
///
/// The axis is **months as a continuous Double**, not calendar months. A fixed mean-month
/// constant keeps the mapping strictly monotonic and timezone-stable, which the ribbon
/// mapping depends on — a calendar-aware month count is non-uniform and would put kinks
/// in the age→offset curve. Calendar awareness lives in ``AgeFormatter``, for display only.
public enum AgeMath {
    /// Seconds in a mean Gregorian month: 365.2425 / 12 days.
    public static let secondsPerMonth: Double = 2_629_746

    /// Age in months of someone born on `birthday` at instant `date`. Negative before birth.
    public static func ageMonths(birthday: Date, at date: Date) -> Double {
        date.timeIntervalSince(birthday) / secondsPerMonth
    }

    /// Inverse of ``ageMonths(birthday:at:)``.
    public static func date(birthday: Date, ageMonths: Double) -> Date {
        birthday.addingTimeInterval(ageMonths * secondsPerMonth)
    }
}
