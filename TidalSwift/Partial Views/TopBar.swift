//
//  TopBar.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 15.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import SwiftUI

struct TopBar: View {
	@EnvironmentObject var appModel: TidalSwiftAppModel

	var body: some View {
		HStack(spacing: 12) {
			Spacer()
			accountButton
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
	}

	// MARK: - Account

	private var accountButton: some View {
		Button {
			appModel.accountInfo()
		} label: {
			Image(systemName: "person.crop.circle")
				.font(.system(size: 18))
		}
		.buttonStyle(.plain)
		.help("Account")
	}
}
