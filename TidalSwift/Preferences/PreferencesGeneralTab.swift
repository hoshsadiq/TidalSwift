//
//  PreferencesGeneralTab.swift
//  TidalSwift
//

import SwiftUI

struct PreferencesGeneralTab: View {
	@EnvironmentObject private var appModel: TidalSwiftAppModel

	@AppStorage("SaveFavoritesOffline") public var saveFavoritesOffline = false

	var body: some View {
		Form {
			Section {
				Toggle("Include EPs and Singles", isOn: $appModel.viewState.newReleasesIncludeEps)
				Toggle("Save Favorites Offline", isOn: $saveFavoritesOffline)
			}
		}
		.formStyle(.grouped)
	}
}
