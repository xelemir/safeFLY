//
//  SettingsView.swift
//  safeFLY
//
//  Created by Jan Grüttefien on 17.11.25.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var droneSettings: DroneSettings
    @Environment(\.dismiss) var dismiss
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    
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
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: NSLocalizedString("Aviation", comment: ""))
                        
                        Toggle("Airports", isOn: $droneSettings.showAirports)
                        Toggle("Aerodromes", isOn: $droneSettings.showAerodromes)
                        Toggle("Control Zones", isOn: $droneSettings.showControlZones)
                        Toggle("Restricted Areas", isOn: $droneSettings.showRestrictedAreas)
                        Toggle("Temporary Restrictions", isOn: $droneSettings.showTemporaryRestrictions)
                        Toggle("Model Flying Fields", isOn: $droneSettings.showModelFlyingFields)
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        SectionHeader(title: NSLocalizedString("Infrastructure", comment: ""))
                        
                        Toggle("Motorways", isOn: $droneSettings.showMotorways)
                        Toggle("Highways", isOn: $droneSettings.showHighways)
                        Toggle("Railways", isOn: $droneSettings.showRailways)
                        Toggle("Waterways", isOn: $droneSettings.showWaterways)
                        Toggle("Industrial Facilities", isOn: $droneSettings.showIndustrial)
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        SectionHeader(title: NSLocalizedString("Restricted Areas", comment: ""))
                        
                        Toggle("Residential Property", isOn: $droneSettings.showResidential)
                        Toggle("Recreational Areas", isOn: $droneSettings.showRecreational)
                        Toggle("Government Buildings", isOn: $droneSettings.showGovernment)
                        Toggle("Nature Reserves", isOn: $droneSettings.showNatureReserves)
                    }
                } header: {
                    Text("Map Layers")
                } footer: {
                    Text("Toggle specific layers to customize which restrictions are displayed on the map.")
                }
                
                Section {
                    Link("Support the Developer", destination: URL(string: "https://buymeacoffee.com/jan04")!)
                    Link("App Webpage & Status", destination: URL(string: "https://gruettecloud.com/safeFLY")!)
                    Link("Contact", destination: URL(string: "https://gruettecloud.com/support")!)
                    Link("GitHub", destination: URL(string: "https://github.com/xelemir/safeFLY")!)
                    Link("DFS DIPUL Datasource", destination: URL(string: "https://uas-betrieb.dfs.de/homepage/")!)
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
}
