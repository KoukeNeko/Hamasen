/// Something the user may want to act on.
///
/// One type, and one property holding it on the model, rather than one
/// property per condition: the window shows one alert at a time.
struct Notice: Equatable {
    let title: String
    let message: String
}
