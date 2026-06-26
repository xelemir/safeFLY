//
//  ZoneAssessmentEvaluator.swift
//  safeFLY
//

import Foundation

enum ZoneAssessmentEvaluator {
    // Country-agnostic: each feature already carries its own verdict (assigned by the
    // provider's normalizer per national rules), so the overall assessment is simply the
    // most restrictive verdict among the matched features.
    nonisolated static func evaluate(features: [ZoneFeature]) -> FlightAssessmentOutcome {
        features
            .map(\.restrictionLevel)
            .max { $0.severityRank < $1.severityRank }
            ?? .allowed
    }
}
