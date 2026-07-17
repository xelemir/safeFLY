//
//  ResidentialRuleNotes.swift
//  safeFLY
//
//  The grey footnote under a tap result explaining what applies over housing in the countries
//  whose authority publishes no residential geometry.
//
//  Only two supported countries map residential areas themselves: Germany (DIPUL ships
//  Wohngrundstücke under §21h LuftVO) and France (the DGAC layer carries the agglomération
//  prohibition). Both are deliberately absent here, because they have real data and a generic
//  reminder next to it would only muddy it.
//
//  Everywhere else the rule is simply not territorial, which is why no feed carries it:
//  Regulation (EU) 2019/947 handles residential areas through the open-category subcategories, so
//  what you may do over houses follows from your drone's C class rather than from any polygon an
//  authority could publish. The note is therefore keyed to two things and nothing else: the
//  country the tap falls in (exact point-in-polygon against the same outlines the providers use)
//  and the pilot's configured drone class. It deliberately makes no claim about whether the
//  tapped point is actually built up, because no data source here can say that. That call is left
//  to the pilot looking at the map.
//
//  Denmark is the one country with a national rule stacked on the EU baseline, and it is exactly
//  the kind of rule this footnote exists for: §19 of the drone bekendtgørelse (BEK 1649 of
//  12/12/2023) forbids overflying an inhabited private property without the occupier's consent,
//  and Bilag 1 of that same regulation states in terms that such properties cannot be shown on
//  dronezoner.dk. The authority itself says the rule is real and unmappable.
//
//  NB: the older Danish "bymæssigt område" (built-up area) permission regime is **repealed**, not
//  current law. It came from BEK 1257 of 2017; the current bekendtgørelse does not define or use
//  the term anywhere, and BEK 2253 of 2020 was repealed by §34 stk. 2. A lot of secondary
//  drone-blog content still repeats it. Do not reintroduce it.
//
//  Switzerland gets an addendum because it is not in the EU and the reason the EU rules apply
//  there is not obvious.
//

import Foundation

enum ResidentialRuleNotes {
    private struct Country {
        let coverage: CountryCoverage
        // A national rule on top of the EU baseline, where one exists.
        let addendumKey: String?
    }

    private static let countries: [Country] = [
        Country(coverage: CountryBoundaries.austria, addendumKey: nil),
        Country(coverage: CountryBoundaries.belgium, addendumKey: nil),
        Country(coverage: CountryBoundaries.denmark, addendumKey: "RESIDENTIAL.INFO.DK"),
        Country(coverage: CountryBoundaries.finland, addendumKey: nil),
        Country(coverage: CountryBoundaries.luxembourg, addendumKey: nil),
        Country(coverage: CountryBoundaries.netherlands, addendumKey: nil),
        Country(coverage: CountryBoundaries.sweden, addendumKey: nil),
        Country(coverage: CountryBoundaries.switzerland, addendumKey: "RESIDENTIAL.INFO.CH")
    ]

    // The footnote for a tapped coordinate, or nil outside the countries this applies to
    // (including Germany and France, which map residential areas themselves).
    nonisolated static func note(for coordinate: MapCoordinate, droneClass: DroneClass) -> String? {
        guard let country = countries.first(where: { $0.coverage.contains(coordinate) }) else {
            return nil
        }

        var paragraphs = [
            NSLocalizedString("RESIDENTIAL.INFO.INTRO", comment: "Footnote: why housing is not on the map"),
            NSLocalizedString(
                classNoteKey(for: droneClass),
                comment: "Footnote: what the pilot's own drone class may do over housing"
            )
        ]
        if let addendumKey = country.addendumKey {
            paragraphs.append(NSLocalizedString(addendumKey, comment: "Footnote: national rule on top of the EU baseline"))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    // C3 and C4 share a note: both sit in A3 and carry the same 150 m separation.
    nonisolated static func classNoteKey(for droneClass: DroneClass) -> String {
        switch droneClass {
        case .c0:
            return "RESIDENTIAL.INFO.C0"
        case .c1:
            return "RESIDENTIAL.INFO.C1"
        case .c2:
            return "RESIDENTIAL.INFO.C2"
        case .c3, .c4:
            return "RESIDENTIAL.INFO.C3C4"
        }
    }
}
