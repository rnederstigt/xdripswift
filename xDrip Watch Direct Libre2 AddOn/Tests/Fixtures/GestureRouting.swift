
final class DirectMode {
    var isDirect = false
    var retries = 0
    func restartConnection() { retries += 1 }
}
final class WatchStateModel {
    let directLibre = DirectMode()
    var phoneRequests = 0
    func requestWatchStateUpdate() { phoneRequests += 1 }
/* @source:double_tap */
}
