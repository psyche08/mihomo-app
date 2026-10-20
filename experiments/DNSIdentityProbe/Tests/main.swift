import Foundation

let now = Date().timeIntervalSince1970
let valid: [String: Any] = ["deadline": now + 300, "strictUnknown": true]
let direct = try ProbeSessionConfiguration(options: valid, now: now)
precondition(direct.strictUnknown && !direct.wrapped)
let wrapped = try ProbeSessionConfiguration(options: ["container": valid], now: now)
precondition(wrapped.strictUnknown && wrapped.wrapped && wrapped.deadline == direct.deadline)
let observation = try ProbeSessionConfiguration(options: ["deadline": now + 300, "strictUnknown": false], now: now)
precondition(!observation.strictUnknown)
let invalid: [[String: Any]?] = [
    nil, [:], ["deadline": now + 300], ["strictUnknown": true],
    ["deadline": now - 1, "strictUnknown": false],
    ["deadline": now + 331, "strictUnknown": false],
    ["deadline": Double.infinity, "strictUnknown": false],
    ["deadline": Double.nan, "strictUnknown": false],
    ["deadline": true, "strictUnknown": false],
    ["deadline": "\(now + 300)", "strictUnknown": false],
    ["deadline": now + 300, "strictUnknown": "true"],
    ["deadline": now + 300, "strictUnknown": 1],
    ["deadline": now + 300, "strictUnknown": false, "extra": 1],
    ["one": valid, "two": valid], ["one": ["two": valid]],
]
for options in invalid {
    do {
        _ = try ProbeSessionConfiguration(options: options, now: now)
        fatalError("Invalid or expired configuration accepted")
    } catch is ProbeSessionConfiguration.Invalid {}
}
print("18 DNS probe configuration checks passed")
