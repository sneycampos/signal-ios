import SwiftUI

struct SupportLinks: View {
    var body: some View {
        Link("Privacy policy", destination: URL(string: "https://wifi-mesh-planner.pages.dev/privacy/")!)
        Link("Contact the developer", destination: URL(string: "mailto:sneycampos@gmail.com")!)
    }
}
