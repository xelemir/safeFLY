//
//  SettingsView.swift
//  safeFLY
//
//  Created by Jan Grüttefien on 17.11.25.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var droneSettings: DroneSettings
    @EnvironmentObject var providersStore: ProvidersStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        return "\(version)"
    }

    var versionText: String {
        String.localizedStringWithFormat(
            NSLocalizedString("App Version %@", comment: "App version label, e.g. \"App Version 1.4.0\""),
            appVersion
        )
    }

    var copyrightText: String {
        // Plain string, not a number, so the year is never grouped (e.g. "2.026" in de).
        let year = String(Calendar.current.component(.year, from: Date()))
        return String.localizedStringWithFormat(
            NSLocalizedString("© %@ Jan Grüttefien and safeFLY contributors", comment: "Copyright notice with current year"),
            year
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Drone Class", selection: $droneSettings.droneClass) {
                        ForEach(DroneClass.allCases, id: \.self) { droneClass in
                            Text(droneClass.description).tag(droneClass)
                        }
                    }
                    
                    TextField("UAV e-ID", text: $droneSettings.operatorID)
                        .textContentType(.none)
                        .autocapitalization(.allCharacters)
                } header: {
                    Text("Drone Information")
                } footer: {
                    Text("Save your UAV e-ID (e.g., DEU3otef849kry8h)")                    
                }
                
                Section {
                    ForEach(providersStore.sessions) { providerSession in
                        NavigationLink {
                            ProviderDetailView(providerSession: providerSession)
                        } label: {
                            ProviderSummaryRow(
                                providerSession: providerSession,
                                isEnabled: providersStore.isProviderEnabled(providerSession.provider.id)
                            )
                        }
                    }
                } header: {
                    Text(NSLocalizedString("Providers", comment: "Providers section title"))
                } footer: {
                    Text(NSLocalizedString(
                        "Each provider covers one country's airspace. Only enable providers for countries you plan to fly in.",
                        comment: "Providers section footer"
                    ))
                }

                Section {
                    Link("Support the Developer", destination: URL(string: "https://buymeacoffee.com/jan04")!)
                    Link("App Webpage & Status", destination: URL(string: "https://gruettecloud.com/safeFLY")!)
                    Link("Contact", destination: URL(string: "mailto:info@gruettecloud.com")!)
                    Link("GitHub", destination: URL(string: "https://github.com/xelemir/safeFLY")!)
                } header: {
                    Text("Resources")
                }
                
                Section {
                    Button {
                        hasCompletedOnboarding = false
                        dismiss()
                    } label: {
                        Text("Play App Introduction Again")
                    }
                } header: {
                    Text("App Setup")
                }
                
                Section {
                    VStack(spacing: 6) {
                        Text(copyrightText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Text(versionText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        openURL(URL(string: "https://jan.gruettefien.com")!)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("Done", comment: "")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(DroneSettings())
        .environmentObject(ProvidersStore(registrations: BuiltInProviders.all))
}
