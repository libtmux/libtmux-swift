import Foundation

package extension Duration {
    var secondsValue: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    var secondsText: String {
        let rendered = String(secondsValue)
        return rendered.hasSuffix(".0") ? String(rendered.dropLast(2)) : rendered
    }
}
