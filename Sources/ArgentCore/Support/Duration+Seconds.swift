extension Duration {
    public var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    public var milliseconds: Double { seconds * 1000 }
}
