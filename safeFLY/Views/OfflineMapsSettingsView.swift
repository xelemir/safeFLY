//
//  OfflineMapsSettingsView.swift
//  safeFLY
//
//  Settings subpage for managing offline map areas: lists downloaded packs with
//  storage info, shows active downloads, and lets the user delete saved areas.
//

import SwiftUI

struct OfflineMapsSettingsView: View {
    @EnvironmentObject private var offlineMapStore: OfflineMapStore

    @State private var packToDelete: OfflineMapPack?
    @State private var showDeleteAlert = false

    var body: some View {
        Form {
            storageSummarySection

            if let activeDownload = offlineMapStore.activeDownload {
                activeDownloadSection(activeDownload)
            }

            downloadedAreasSection
        }
        .navigationTitle(NSLocalizedString("Offline Maps", comment: "Offline maps settings title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            offlineMapStore.loadPacks()
        }
        .alert(
            NSLocalizedString("Delete Area", comment: "Delete area alert title"),
            isPresented: $showDeleteAlert
        ) {
            Button(NSLocalizedString("Cancel", comment: "Cancel button"), role: .cancel) {
                packToDelete = nil
            }
            Button(NSLocalizedString("Delete", comment: "Delete button"), role: .destructive) {
                if let pack = packToDelete {
                    offlineMapStore.deletePack(pack)
                    packToDelete = nil
                }
            }
        } message: {
            Text(NSLocalizedString("DELETE_AREA_CONFIRMATION", comment: "Delete area confirmation message"))
        }
    }

    // MARK: - Sections

    private var storageSummarySection: some View {
        Section {
            HStack {
                Text(NSLocalizedString("Storage Used", comment: "Storage used label"))
                Spacer()
                Text(ByteCountFormatter.string(
                    fromByteCount: offlineMapStore.totalStorageBytes,
                    countStyle: .file
                ))
                .foregroundStyle(.secondary)
            }

            HStack {
                Text(NSLocalizedString("Downloaded Areas", comment: "Downloaded areas count label"))
                Spacer()
                Text("\(offlineMapStore.packs.count)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func activeDownloadSection(_ download: ActiveDownload) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(download.name)
                        .font(.headline)
                    Spacer()
                    Text(NSLocalizedString("Downloading...", comment: "Downloading in progress"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: download.progress)

                HStack {
                    Text("\(download.completedResources) / \(download.expectedResources)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(download.progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(role: .destructive) {
                offlineMapStore.cancelActiveDownload()
            } label: {
                Text(NSLocalizedString("Cancel Download", comment: "Cancel download button"))
            }
        } header: {
            Text(NSLocalizedString("Active Download", comment: "Active download section header"))
        }
    }

    private var downloadedAreasSection: some View {
        Section {
            if offlineMapStore.packs.isEmpty {
                Text(NSLocalizedString("No Downloaded Areas", comment: "No downloaded areas placeholder"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(offlineMapStore.packs) { pack in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pack.name)
                                .font(.body)

                            Text(pack.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(ByteCountFormatter.string(
                            fromByteCount: pack.sizeBytes,
                            countStyle: .file
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            packToDelete = pack
                            showDeleteAlert = true
                        } label: {
                            Label(
                                NSLocalizedString("Delete", comment: "Delete swipe action"),
                                systemImage: "trash"
                            )
                        }
                    }
                }
            }
        } header: {
            Text(NSLocalizedString("Downloaded Areas", comment: "Downloaded areas section header"))
        } footer: {
            // Plain informative footnote rather than its own tile: it explains what offline
            // covers, it is not a setting.
            Text(NSLocalizedString("OFFLINE_MAPS_INFO_FOOTER", comment: "Offline maps info footer"))
        }
    }
}

#Preview {
    NavigationStack {
        OfflineMapsSettingsView()
            .environmentObject(OfflineMapStore())
    }
}
