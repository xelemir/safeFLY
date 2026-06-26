//
//  ZoneAssessmentEvaluator.swift
//  safeFLY
//

import Foundation

enum ZoneAssessmentEvaluator {
    nonisolated static func evaluate(features: [ZoneFeature]) -> FlightAssessmentOutcome {
        if features.contains(where: isProhibited) {
            return .prohibited
        }

        if features.contains(where: isConditional) {
            return .conditional
        }

        return .allowed
    }

    nonisolated private static func isProhibited(_ feature: ZoneFeature) -> Bool {
        switch feature.category {
        case .airport, .temporaryRestrictionActive:
            return true
        default:
            return false
        }
    }

    nonisolated private static func isConditional(_ feature: ZoneFeature) -> Bool {
        switch feature.category {
        case .airport, .temporaryRestrictionActive:
            return false
        default:
            return true
        }
    }
}
