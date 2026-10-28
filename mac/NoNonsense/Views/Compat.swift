import SwiftUI

// Liquid Glass and scroll edge effects are macOS 26 and iOS 26 only; the iPhone app shares this file. Every glass use
// goes through these, so the other look is decided once: a material in the same shape, the bordered button styles, and
// no glass groups or morphs. That look is macOS 15's and iOS 18's, and the 26 releases' with Settings › Appearance ›
// Liquid Glass off. Glass on, each is exactly the call it replaces.

enum GlassSetting {
    static let key = "liquidGlass"
}

extension View {
    /// `.glassEffect(.regular[.tint(tint)][.interactive()], in: shape)`; `enabled: false` is `.identity` (no glass).
    func compatGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil, enabled: Bool = true) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive, tint: tint, enabled: enabled))
    }

    /// `.buttonStyle(.glass)`, or `.glassProminent` when `prominent`.
    func compatGlassButton(prominent: Bool = false) -> some View {
        modifier(GlassButton(prominent: prominent))
    }

    /// `.glassEffectID(id, in: namespace)`: glass shapes that morph into each other.
    func compatGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        modifier(GlassID(id: id, namespace: namespace))
    }

    /// `.glassEffectTransition(.materialize)`.
    func compatGlassMaterialize() -> some View {
        modifier(GlassMaterialize())
    }

    /// `.scrollEdgeEffectHidden(true, for: .top)`: macOS 15 draws no edge effect to hide.
    @ViewBuilder
    func compatTopEdgeEffectHidden() -> some View {
        if #available(macOS 26, iOS 26, *) { self.scrollEdgeEffectHidden(true, for: .top) } else { self }
    }
}

private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let tint: Color?
    let enabled: Bool
    @AppStorage(GlassSetting.key) private var liquidGlass = true

    func body(content: Content) -> some View {
        if #available(macOS 26, iOS 26, *), liquidGlass {
            content.glassEffect(glass, in: shape)
        } else if enabled {
            content.background { ZStack { shape.fill(.regularMaterial); if let tint { shape.fill(tint) } } }
        } else {
            content
        }
    }

    @available(macOS 26, iOS 26, *)
    private var glass: Glass {
        guard enabled else { return .identity }
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        return interactive ? glass.interactive() : glass
    }
}

private struct GlassButton: ViewModifier {
    let prominent: Bool
    @AppStorage(GlassSetting.key) private var liquidGlass = true

    func body(content: Content) -> some View {
        if #available(macOS 26, iOS 26, *), liquidGlass {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }
}

private struct GlassID<ID: Hashable & Sendable>: ViewModifier {
    let id: ID
    let namespace: Namespace.ID
    @AppStorage(GlassSetting.key) private var liquidGlass = true

    func body(content: Content) -> some View {
        if #available(macOS 26, iOS 26, *), liquidGlass { content.glassEffectID(id, in: namespace) } else { content }
    }
}

private struct GlassMaterialize: ViewModifier {
    @AppStorage(GlassSetting.key) private var liquidGlass = true

    func body(content: Content) -> some View {
        if #available(macOS 26, iOS 26, *), liquidGlass { content.glassEffectTransition(.materialize) } else { content }
    }
}

/// `GlassEffectContainer(spacing:)`: glass shapes inside it blend as one. Without glass, the content alone.
struct CompatGlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content
    @AppStorage(GlassSetting.key) private var liquidGlass = true

    var body: some View {
        if #available(macOS 26, iOS 26, *), liquidGlass { GlassEffectContainer(spacing: spacing) { content } } else { content }
    }
}
