import Foundation
import PadStepsCore

private struct GapOperationRejected: LocalizedError {
    var errorDescription: String? { "Google rejected the gap save. Use Retry rejected gap save after reviewing the walk files." }
}

extension PadMonitor {
    func retryRejectedGaps(_ id: UUID) {
        guard !syncing, var walk = state.walks.first(where: { $0.id == id }),
              let plan = walk.gapExport, !(plan.rejectedCreations ?? []).isEmpty else { return }
        // Only explicit, definitive rejections appear in this list. Unknown
        // outcomes retain their attempt marker and can only be searched/adopted.
        walk.gapExport = plan.retryingRejectedCreations(); walk.status = "verifying"
        do { try update(walk); retrySync() } catch { self.error = error.localizedDescription }
    }
    private func timeRange(_ point: [String: Any]) -> WorkoutTimeRange? {
        guard let exercise = point["exercise"] as? [String: Any],
              let interval = exercise["interval"] as? [String: Any],
              let left = interval["startTime"] as? String, let right = interval["endTime"] as? String,
              let start = Self.date(left), let end = Self.date(right), end > start else { return nil }
        return .init(start: start, end: end)
    }

    private func receipt(_ point: [String: Any], walk: AutomaticWalk) -> MeasuredWalkReceipt? {
        guard let key = try? CorrectionSigner.key(),
              let value = MeasuredWalkReceipt.verifiedAll(point: point, publicKey: key.publicKey.rawRepresentation, clientID: google.clientID).first(where: { $0.sessionID == walk.id }),
              value.steps == walk.steps,
              abs(value.start.timeIntervalSince(walk.start)) < 0.002,
              abs(value.end.timeIntervalSince(walk.exportEnd)) < 0.002 else { return nil }
        return value
    }

    private func ownGap(_ point: [String: Any], walk: AutomaticWalk) -> Bool {
        guard receipt(point, walk: walk)?.gap == true,
              let source = point["dataSource"] as? [String: Any], source["platform"] as? String == "GOOGLE_WEB_API",
              let app = source["application"] as? [String: Any] else { return false }
        return (app["googleWebClientId"] as? String ?? app["webClientId"] as? String) == google.clientID
    }

    private func pointIfPresent(_ resource: String) async throws -> [String: Any]? {
        do { return try await google.request("GET", resource) }
        catch let error as GoogleHTTPError where error.status == 404 { return nil }
    }

    private func complete(_ operation: [String: Any], name: String?) async throws {
        let value: [String: Any]
        if operation["done"] as? Bool == true { value = operation }
        else if let resource = operation["name"] as? String ?? name { value = try await google.request("GET", resource) }
        else { return }
        if value["error"] != nil { throw GapOperationRejected() }
    }

    func syncGapExport(walk: inout AutomaticWalk) async throws {
        let all = try await workouts(near: walk)
        let ownedNames = Set((walk.gapExport?.resources ?? []) + (walk.gapExport?.retiredResources ?? []))
        let existing = all.filter { point in
            guard let name = point["name"] as? String else { return false }
            return !ownedNames.contains(name) && !ownGap(point, walk: walk)
        }
        let walking = existing.filter { ($0["exercise"] as? [String: Any])?["exerciseType"] as? String == "WALKING" }
        if existing.count != walking.count {
            walk.status = "review"; walk.reviewKind = "coverageExport"
            walk.detail = "A different kind of workout overlaps this walk. Review it in Google Health; PadSteps has not created an overlapping workout."
            try update(walk); return
        }
        let gaps = WorkoutCoverage.missing(in: .init(start: walk.start, end: walk.exportEnd), covered: walking.compactMap(timeRange))
        let user = state.healthUserID ?? ""
        guard !user.isEmpty else { throw PadError.message("Google account identity is not available yet.") }
        var plan = walk.gapExport ?? .init(gaps: gaps)
        let oldResources = plan.resources
        let desiredNames = gaps.indices.map { index in
            index < oldResources.count ? oldResources[index] : "users/\(user)/dataTypes/exercise/dataPoints/padsteps-\(walk.id.uuidString.lowercased())-\(index)"
        }
        plan.retiredResources = Array(Set(plan.retiredResources + oldResources.filter { !desiredNames.contains($0) })).sorted()
        if walk.gapExport == nil || plan.gaps != gaps { walk.status = "verifying"; walk.reviewKind = "coverageExport" }
        plan.gaps = gaps; plan.resources = desiredNames
        walk.gapExport = plan; try update(walk)
        _ = try writeWalkFeed()

        var heart: [HeartObservation]?
        for (index, gap) in gaps.enumerated() {
            var name = walk.gapExport!.resources[index]
            let provisional = name.split(separator: "/").last?.hasPrefix("padsteps-") == true
            var found: [String: Any]?
            if provisional {
                let candidates = try await workouts(near: walk).filter { point in
                    guard ownGap(point, walk: walk), let range = timeRange(point) else { return false }
                    return abs(range.start.timeIntervalSince(gap.start)) < 0.002 && abs(range.end.timeIntervalSince(gap.end)) < 0.002
                }
                guard candidates.count <= 1 else { throw PadError.message("Multiple matching gap workouts exist. No additional workout was created.") }
                if let candidate = candidates.first, let assigned = candidate["name"] as? String {
                    name = assigned; walk.gapExport?.resources[index] = name; found = candidate; try update(walk)
                } else if walk.gapExport?.rejectedCreations?.contains(name) == true {
                    throw GapOperationRejected()
                } else if walk.gapExport?.creationStarted?[name] == true {
                    throw PadError.message("The gap save is not confirmed yet. Check again searches for the original attempt; another workout will not be created.")
                }
            } else { found = try await pointIfPresent(name) }
            if found == nil, walk.gapExport?.confirmedResources?.contains(name) == true {
                throw PadError.message("A previously saved gap workout is missing. It was not recreated automatically; keep this walk locally or inspect its saved files.")
            }
            if let found {
                guard ownGap(found, walk: walk) || (name == plan.legacyResource && matches(found, walk: walk)) else {
                    throw PadError.message("A gap workout was changed or belongs to another source. It was not overwritten. Show walk files to inspect it.")
                }
                if let range = timeRange(found), abs(range.start.timeIntervalSince(gap.start)) < 0.002,
                   abs(range.end.timeIntervalSince(gap.end)) < 0.002, receipt(found, walk: walk) != nil { continue }
            }
            if heart == nil && walk.heartRateOmitted != true {
                let points = try await google.pages("users/me/dataTypes/heart-rate/dataPoints", query: [
                    "pageSize": "10000", "dataSourceFamily": "users/me/dataSourceFamilies/google-wearables",
                    "filter": "heart_rate.sample_time.physical_time >= \"\(Self.iso(walk.start))\" AND heart_rate.sample_time.physical_time < \"\(Self.iso(walk.exportEnd))\""])
                try evidence("gap-heart-rate", walk: walk, value: points)
                heart = points.compactMap { point in
                    guard let source = point["dataSource"] as? [String: Any], source["platform"] as? String == "FITBIT",
                          let device = source["device"] as? [String: Any], device["displayName"] as? String == "Fitbit Air",
                          let h = point["heartRate"] as? [String: Any], let sample = h["sampleTime"] as? [String: Any],
                          let text = sample["physicalTime"] as? String, let at = Self.date(text),
                          let bpm = Int(String(describing: h["beatsPerMinute"] ?? "")) else { return nil }
                    return .init(at: at, bpm: bpm)
                }
            }
            var metrics: [String: Any] = [:]
            if abs(gap.start.timeIntervalSince(walk.start)) < 0.002 && abs(gap.end.timeIntervalSince(walk.exportEnd)) < 0.002 {
                metrics["steps"] = String(walk.steps); metrics["distanceMillimeters"] = walk.metres * 1000
            }
            if walk.heartRateOmitted != true {
                do { metrics["averageHeartRateBeatsPerMinute"] = String(try HeartSummary.calculate(heart ?? [], start: gap.start, end: gap.end).average) }
                catch let error as HeartCoverageError {
                    walk.status = "waitingHeartRate"; walk.detail = error.localizedDescription; try update(walk); return
                }
            }
            let signed = try MeasuredWalkReceipt(walk: walk, resource: found == nil ? "unassigned" : name, carrier: gap, gap: true, clientID: google.clientID)
                .signedNote(privateKey: CorrectionSigner.key().rawRepresentation)
            var body: [String: Any] = ["name": name,
                "dataSource": ["recordingMethod": "ACTIVELY_MEASURED", "platform": "GOOGLE_WEB_API"],
                "exercise": ["exerciseType": "WALKING", "interval": ["startTime": Self.iso(gap.start), "endTime": Self.iso(gap.end),
                    "startUtcOffset": "\(TimeZone.current.secondsFromGMT(for: gap.start))s", "endUtcOffset": "\(TimeZone.current.secondsFromGMT(for: gap.end))s"],
                    "activeDuration": String(format: "%.3fs", gap.seconds), "metricsSummary": metrics, "notes": signed]]
            try evidence("gap-\(index)-payload", walk: walk, value: body)
            walk.uploadAttempted = true; walk.status = "verifying"; walk.detail = "Saving only the time missing from Google's workouts…"; try update(walk)
            var operation: [String: Any]
            if found == nil {
                body.removeValue(forKey: "name")
                var started = walk.gapExport?.creationStarted ?? [:]; started[name] = true
                walk.gapExport?.creationStarted = started; try update(walk)
                do { operation = try await google.request("POST", "users/me/dataTypes/exercise/dataPoints", body: body) }
                catch let error as GoogleHTTPError where [400, 403, 422].contains(error.status) {
                    let rejected = Array(Set((walk.gapExport?.rejectedCreations ?? []) + [name]))
                    walk.gapExport?.rejectedCreations = rejected; try update(walk); throw error
                }
            } else {
                var patch = body; patch.removeValue(forKey: "dataSource")
                operation = try await google.request("PATCH", name, body: patch)
            }
            try evidence("gap-\(index)-operation", walk: walk, value: operation)
            if let operationName = operation["name"] as? String {
                var pending = walk.gapExport?.operations ?? [:]; pending[name] = operationName
                walk.gapExport?.operations = pending; try update(walk)
            }
            do { try await complete(operation, name: walk.gapExport?.operations?[name]) }
            catch let error as GapOperationRejected {
                if provisional {
                    let rejected = Array(Set((walk.gapExport?.rejectedCreations ?? []) + [name]))
                    walk.gapExport?.rejectedCreations = rejected; try update(walk)
                }
                throw error
            }
            if name.split(separator: "/").last?.hasPrefix("padsteps-") == true {
                let candidates = try await workouts(near: walk).filter { point in
                    guard ownGap(point, walk: walk), let range = timeRange(point) else { return false }
                    return abs(range.start.timeIntervalSince(gap.start)) < 0.002 && abs(range.end.timeIntervalSince(gap.end)) < 0.002
                }
                if candidates.count == 1, let assigned = candidates.first?["name"] as? String {
                    name = assigned; walk.gapExport?.resources[index] = name; found = candidates.first; try update(walk)
                } else { found = nil }
            } else { found = try await pointIfPresent(name) }
            guard let found, ownGap(found, walk: walk), let range = timeRange(found),
                  abs(range.start.timeIntervalSince(gap.start)) < 0.002, abs(range.end.timeIntervalSince(gap.end)) < 0.002 else {
                throw PadError.message("Google has not confirmed the gap workout yet. Check again uses the same identity, never a second copy.")
            }
            try evidence("gap-\(index)-readback", walk: walk, value: found)
            let confirmed = Array(Set((walk.gapExport?.confirmedResources ?? []) + [name])).sorted()
            walk.gapExport?.confirmedResources = confirmed
            try update(walk)
        }

        // Fitbit owns its records. Measured steps travel in the signed local
        // feed, so a fully covered walk never needs a synthetic Google workout.
        let carrier = gaps.isEmpty ? walking.first?["name"] as? String : walk.gapExport?.resources.first
        walk.gapExport?.carrier = carrier

        for name in walk.gapExport?.retiredResources ?? [] {
            if let point = try await pointIfPresent(name) {
                guard ownGap(point, walk: walk) || (name == plan.legacyResource && matches(point, walk: walk)) else { throw PadError.message("An old gap workout was changed. It was not removed automatically.") }
                try evidence("retired-gap-\(name.split(separator: "/").last!)", walk: walk, value: point)
                let operation = try await google.request("POST", "users/\(user)/dataTypes/exercise/dataPoints:batchDelete", body: ["names": [name]])
                try await complete(operation, name: nil)
                guard try await pointIfPresent(name) == nil else { throw PadError.message("Removal of the old gap workout is still being confirmed.") }
            }
            walk.gapExport?.retiredResources.removeAll { $0 == name }
            walk.gapExport?.confirmedResources?.removeAll { $0 == name }; try update(walk)
        }
        walk.gapExport?.checkedAt = Date(); walk.resourceName = walk.gapExport?.carrier
        walk.status = "saved"; walk.reviewKind = nil
        let missingSeconds = gaps.reduce(0.0) { $0 + $1.seconds }
        walk.detail = gaps.isEmpty ? "Google already recorded this walk. No extra workout added • measured steps ready for iPhone sync" : "Saved \(Int(missingSeconds.rounded())) seconds missing from Google across \(gaps.count) workout\(gaps.count == 1 ? "" : "s") • measured steps ready for iPhone sync"
        try update(walk)
    }
}
