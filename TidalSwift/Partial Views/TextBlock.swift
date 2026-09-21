//
//  TextBlock.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 21.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI

/// A `TEXT_BLOCK` module: an indented, secondary paragraph.
struct TextBlock: View {
	let text: String

	var body: some View {
		Text(text)
			.font(.body)
			.foregroundColor(.secondary)
			.fixedSize(horizontal: false, vertical: true)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 32)
	}
}
