//
//  DownloadIndicator.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 03.12.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

struct DownloadIndicator: View {
	@State private var animationState = false
	@State private var animationTask: Task<Void, Never>?

	@Environment(DownloadStatus.self) private var downloadStatus

	var body: some View {
		Group {
			if downloadStatus.downloadingTasks > 0 {
				Text(animationState ? "􀈉" : "􀈈")
					.onAppear {
						animationTask?.cancel()
						animationTask = Task {
							while true {
								do {
									try await Task.sleep(for: .seconds(1))
								} catch {
									return
								}
								animationState.toggle()
							}
						}
					}
					.help("Downloads currently running")
					.onDisappear {
						animationTask?.cancel()
						animationTask = nil
					}
			}
		}
	}
}

struct DownloadIndicator_Previews: PreviewProvider {
	static var previews: some View {
		DownloadIndicator()
	}
}
