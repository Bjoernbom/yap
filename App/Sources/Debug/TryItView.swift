#if DEBUG
import SwiftUI

/// A text box inside yap to dictate into during verification, so synthetic
/// keys and inserted text never land in someone else's window. A stand-in
/// for onboarding's "try it" step (M4). Open it from Debug → Try it window,
/// with `-YapOpenWindows YES`, or by posting the distributed notification
/// `com.bjornbom.yap.debug.tryIt`, which also brings it to the front.
/// The password field checks that dictation never types into one.
struct TryItView: View {
	@State private var text = ""
	@State private var password = ""

	var body: some View {
		VStack(spacing: 8) {
			TextEditor(text: $text)
				.font(.body)
			SecureField("Password", text: $password)
		}
		.padding(8)
		.frame(minWidth: 360, minHeight: 180)
	}
}
#endif
