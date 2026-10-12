import SwiftUI

// macOS 15 has no Liquid Glass and no scroll edge effects (both macOS 26). Every use goes through these, so the older
// look is decided once: glass becomes a material in the same shape, the glass button styles the bordered ones, and a
// glass group or morph is simply left out. On macOS 26 each one is exactly the call it replaces.

extension View {
    /// `.glassEffect(.regular[.tint(tint)][.interactive()], in: shape)`; `enabled: false` is `.identity` (no glass).
    @ViewBuilder
    func compatGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil, enabled: Bool = true) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(Self.glass(interactive: interactive, tint: tint, enabled: enabled), in: shape)
        } else if enabled {
            self.background { ZStack { shape.fill(.regularMaterial); if let tint { shape.fill(tint) } } }
        } else {
            self
        }
    }

    @available(macOS 26, *)
    private static func glass(interactive: Bool, tint: Color?, enabled: Bool) -> Glass {
        guard enabled else { return .identity }
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        return interactive ? glass.interactive() : glass
    }

    /// `.buttonStyle(.glass)`, or `.glassProminent` when `prominent`.
    @ViewBuilder
    func compatGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }

    /// `.glassEffectID(id, in: namespace)`: glass shapes that morph into each other. Nothing to morph on macOS 15.
    @ViewBuilder
    func compatGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26, *) { self.glassEffectID(id, in: namespace) } else { self }
    }

    /// `.glassEffectTransition(.materialize)`.
    @ViewBuilder
    func compatGlassMaterialize() -> some View {
        if #available(macOS 26, *) { self.glassEffectTransition(.materialize) } else { self }
    }

    /// `.scrollEdgeEffectHidden(true, for: .top)`: macOS 15 draws no edge effect to hide.
    @ViewBuilder
    func compatTopEdgeEffectHidden() -> some View {
        if #available(macOS 26, *) { self.scrollEdgeEffectHidden(true, for: .top) } else { self }
    }
}

/// `GlassEffectContainer(spacing:)`: glass shapes inside it blend as one. On macOS 15 the content alone.
struct CompatGlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { content } } else { content }
    }
}
