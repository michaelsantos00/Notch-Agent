# NotchAgent brand

Selected direction: **Inverse** — a graphite tile, white notch silhouette, and three black status lights. The lights suggest the independent agents the app observes. The flared top joins the shape to an imagined display edge.

- Name: **NotchAgent**, one word, capital N and A.
- Descriptor: **Your agents. Your limits. One notch.**
- Palette: Ink `#0E0E0E`, Paper `#F7F7F7`; supporting grays only.
- Typography: the native system sans serif in the app; outlined Helvetica Neue Medium for portable SVG wordmarks. No font files are bundled.
- Primary icon: `icon-inverse.png`, 1024 × 1024.
- Marks: `mark-black.svg` and `mark-white.svg`, with transparent cutouts.
- Wordmarks: `wordmark-black.svg` and `wordmark-white.svg`, with outlined lettering.
- Banner: `banner.png`, 1600 × 600.
- Brand presentation: `brand-board.png`, with three explored directions.

Use the white mark on dark surfaces and black mark on light surfaces. Preserve the shape, keep clear space of at least one status-dot diameter, and avoid adding colors, shadows, or type inside the mark. System menu-bar tinting uses a monochrome template. Provider logos and status colors retain their semantic meanings; they are not NotchAgent brand colors.

Generate locally:

```sh
swift Scripts/generate-brand.swift
swift Scripts/generate-brand.swift --install
```

The first command regenerates previews and vector masters. The second also installs the selected Inverse icon in all ten macOS asset slots and the menu-bar template, plus Windows app/tray PNGs and the multi-size ICO. No image-generation service or downloaded font is used.

Compatibility identifiers such as `com.vinz.codenotch`, Application Support/Codenotch, existing Keychain services, and Rust crate names remain stable to preserve settings, credentials, and existing integrations. Current app labels, targets, products, and branding use NotchAgent. Historical release archives and the upstream MIT attribution retain the original project's name.
