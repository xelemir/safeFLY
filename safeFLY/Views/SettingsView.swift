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
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    private var supportsProviderReordering: Bool {
        providersStore.sessions.count > 1
    }
    
    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        return "\(version)"
    }
    
    var copyrightText: String {
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) Jan Grüttefien and safeFLY contributors"
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
                    if supportsProviderReordering {
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
                        .onMove(perform: providersStore.moveProviders)
                    } else {
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
                    }
                } header: {
                    Text(NSLocalizedString("Providers", comment: "Providers section title"))
                } footer: {
                    Text(NSLocalizedString(
                        supportsProviderReordering
                        ? "Manage built-in geospatial providers, reorder their precedence, and configure their provider-specific datasets."
                        : "Manage the built-in geospatial provider and configure its provider-specific datasets.",
                        comment: "Providers section footer"
                    ))
                }
                
                Section {
                    Link("Support the Developer", destination: URL(string: "https://buymeacoffee.com/jan04")!)
                    Link("App Webpage & Status", destination: URL(string: "https://gruettecloud.com/safeFLY")!)
                    Link("Contact", destination: URL(string: "https://gruettecloud.com/support")!)
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
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("About")
                } footer: {
                    Link(destination: URL(string: "https://jan.gruettefien.com")!) {
                        Text(copyrightText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if supportsProviderReordering {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                    }
                }

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
