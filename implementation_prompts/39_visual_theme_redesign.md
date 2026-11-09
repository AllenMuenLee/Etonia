# Etonia — Visual Theme Redesign Implementation

## Objective

You are a senior Flutter UI engineer and visual design system specialist.

Your task is to redesign the **visual styling of Etonia's existing UI** into a cohesive, premium, minimalist, and slightly editorial design system.

**Design direction: Premium Minimalism × Modern Stationery × Soft Editorial.**

Etonia is a note-taking and study application designed for students, from secondary school through university.

The new theme should communicate:

- Premium craftsmanship and attention to detail.
- Warmth and approachability.
- Minimalism without looking generic or sterile.
- A subtle stationery-inspired atmosphere.
- Modern, polished, Apple-like visual quality.
- A restrained, slightly artistic personality.

The result should feel like a beautifully designed digital notebook and study workspace, not a children's educational app or a heavily illustrated journal.

## Critical Scope Restrictions

This is strictly a **visual theme redesign**.

Do not change:

- Existing icons or their underlying icon assets.
- Existing layout structures.
- Navigation hierarchy or routing.
- Screen compositions.
- Component hierarchy.
- Feature placements.
- User interactions.
- Business logic.
- Data models.
- AI functionality.
- Storage, synchronization, or networking.
- Subscription systems.
- Existing animations unless visual-state styling requires minor adjustments.

Do not introduce new components, screens, decorative illustrations, or navigation elements.

Preserve the application's established information architecture and spatial relationships.

You may adjust visual properties including:

- Color.
- Typography.
- Font weights.
- Text contrast and hierarchy.
- Corner radius.
- Borders.
- Shadows.
- Surface treatments.
- Component fill styles.
- Icon color and stroke presentation where technically supported.
- Hover, focus, pressed, selected, and disabled styling.
- Subtle padding and spacing corrections where necessary for visual consistency.

The main goal is a coherent theme, not a structural redesign.

---

# 1. Core Visual Direction

Establish a visual language based on the current Etonia logo, which features a bold geometric letter E with a folded-paper corner.

Use the logo's design characteristics as inspiration:

- Simple geometric shapes.
- Controlled rounded corners.
- Clean contours.
- Strong negative space.
- Precise visual alignment.
- Limited accent colors.
- Minimal decoration.

Balance this geometric foundation with softer, more approachable visual styling.

The overall appearance should be:

**75% clean contemporary minimalism, 20% refined stationery-inspired warmth, 5% subtle editorial character.**

These proportions represent design emphasis, not literal color or screen coverage.

Avoid:

- Excessive gradients.
- Neon colors.
- Heavy glassmorphism.
- Strong drop shadows.
- Overly colorful interfaces.
- Excessively rounded pill-shaped components.
- Thick ornamental borders.
- Skeuomorphic paper textures.
- Heavy handwritten typography.
- Unnecessary visual effects.

The product should remain suitable for extended academic work.

---

# 2. Color System

Implement a centralized semantic color palette supporting light and dark modes.

Reuse the existing theme architecture where possible.

Do not introduce competing theme systems or hardcoded colors throughout individual components.

## 2.1 Light Theme

| Token | Hex | Usage |
|---|---|---|
| backgroundPrimary | #FAF9F7 | Main application background |
| backgroundSecondary | #F3F2F0 | Secondary navigation surfaces |
| surfacePrimary | #FFFFFF | Primary cards and panels |
| surfaceSecondary | #F7F6F4 | Nested surfaces |
| surfaceElevated | #FFFFFF | Dialogs and popovers |
| textPrimary | #252329 | Main text |
| textSecondary | #706D76 | Secondary text |
| textTertiary | #96919C | Muted labels |
| borderSubtle | #E9E6E9 | Dividers and delicate borders |
| borderStrong | #D4CFD8 | More prominent borders |
| brandPrimary | #8873B4 | Brand accent |
| brandHover | #7761A5 | Hover state |
| brandPressed | #66518F | Pressed state |
| brandSubtle | #F0EBF8 | Subtle brand surfaces |
| selectedSurface | #EEE8F7 | Selected elements |
| success | #408B75 | Positive feedback |
| warning | #B68036 | Warning |
| error | #C45757 | Destructive actions |
| focusRing | #A58DCC | Keyboard focus |

### Light Theme Rules

Use warm off-white rather than cold gray as the primary background.

Cards should remain predominantly white.

Lavender should be used sparingly, primarily for interactive emphasis.

Avoid large lavender backgrounds in functional workspaces.

The interface should feel warm without appearing beige or vintage.

Do not apply visible paper textures to functional UI surfaces.

The stationery influence should be communicated through color temperature, typography, and visual craftsmanship.

## 2.2 Dark Theme

| Token | Hex |
|---|---|
| backgroundPrimary | #161519 |
| backgroundSecondary | #1E1D22 |
| surfacePrimary | #25242A |
| surfaceSecondary | #2D2B32 |
| surfaceElevated | #333039 |
| textPrimary | #F5F2F6 |
| textSecondary | #B7B1BD |
| textTertiary | #8E8795 |
| borderSubtle | #3C3842 |
| borderStrong | #56505D |
| brandPrimary | #B8A2DF |
| brandHover | #C5B3E7 |
| brandPressed | #A48CD4 |
| brandSubtle | #332A40 |
| selectedSurface | #40344E |
| success | #79BFA6 |
| warning | #DDB16C |
| error | #DF898B |
| focusRing | #B8A2DF |

### Dark Theme Rules

Use layered charcoal surfaces instead of pure black everywhere.

Avoid excessive contrast between adjacent panels.

Use borders and subtle tonal differences to distinguish surfaces.

Maintain comfortable contrast for extended reading.

Do not simply invert the light theme.

Keep user-created document backgrounds independent from the surrounding app theme.

---

# 3. Typography

## 3.1 Font Direction

Use a refined two-font system:

**Primary UI Font: Inter**

Apply to the majority of existing UI:

- Navigation.
- Body text.
- Buttons.
- Inputs.
- Settings.
- Menus.
- Toolbars.
- Dialogs.
- Cards.
- Tooltips.
- AI interfaces.
- Study controls.

Inter should define the overall application character.

**Secondary Editorial Font: Newsreader**

Use selectively for large, low-density titles where the existing layout supports it.

Examples include existing prominent dashboard or welcome headings.

Do not introduce new headings to justify using this font.

Do not apply Newsreader to:

- Buttons.
- Navigation.
- Form labels.
- Dense card content.
- Small text.
- Technical explanations.
- Mathematical content.

Keep the application predominantly sans-serif.

If font changes create layout overflow, prioritize readability and layout preservation over decorative typography.

Use appropriate fallback fonts for Chinese, Japanese, Korean, mathematical notation, and other unsupported glyphs.

## 3.2 Typography Tokens

| Style | Size | Weight | Line Height |
|---|---:|---|---:|
| display | 34 | 500 | 1.15 |
| headingLarge | 28 | 600 | 1.20 |
| headingMedium | 22 | 600 | 1.25 |
| headingSmall | 18 | 600 | 1.30 |
| bodyLarge | 16 | 400 | 1.50 |
| bodyMedium | 14 | 400 | 1.45 |
| bodySmall | 13 | 400 | 1.40 |
| label | 13 | 500 | 1.35 |
| caption | 12 | 400 | 1.40 |
| micro | 11 | 500 | 1.30 |

Use these as baseline logical-pixel values, not rigid accessibility limits.

Respect operating-system font scaling and existing user font preferences.

## 3.3 Typography Refinement

Use medium-weight headings instead of excessive boldness.

Maintain strong hierarchy through spacing, size, and contrast rather than weight alone.

Use sentence case unless the existing text requires otherwise.

Avoid excessive uppercase styling.

Apply slight negative letter spacing only to large headings.

Use tabular numerals for timers, scores, dates, and statistics.

Preserve existing user-authored note typography, formatting, and PDF font rendering.

---

# 4. Existing Icon Styling

Preserve all current icon assets, icon meanings, positions, and interactions.

Do not replace or redefine icons.

Standardize only their visual presentation.

### Icon Color

Default icons should use textSecondary.

Active or selected icons should use brandPrimary when appropriate.

Disabled icons should use a muted disabled color.

Destructive actions should use error.

### Icon Treatment

Avoid decorative backgrounds behind every icon.

Avoid gradients and strong icon shadows.

Keep icon sizes consistent with the existing component hierarchy.

Where the existing icon library allows it, normalize visual weight without altering recognizability.

Maintain optical alignment.

Preserve established platform conventions and accessibility labels.

---

# 5. Shape and Surface System

Use a restrained rounding system.

| Token | Radius |
|---|---:|
| radiusXS | 4px |
| radiusSM | 8px |
| radiusMD | 12px |
| radiusLG | 16px |
| radiusXL | 22px |
| radiusXXL | 28px |

Suggested applications:

- Compact controls: 8px.
- Standard buttons and inputs: 10–12px.
- Cards: 12–16px.
- Floating panels: 16px.
- Dialogs: 20–22px.

Avoid applying 24–32px corner radii indiscriminately.

Favor well-proportioned geometry.

## 5.1 Borders

Use subtle neutral borders to define component boundaries.

Default border width: approximately 1px.

Avoid dark borders on every component.

Selected states may use slightly stronger borders or tinted surfaces.

## 5.2 Shadows

Use very subtle shadows only where elevation communicates hierarchy.

Recommended light-theme elevation styles:

**Low elevation**

- Y offset: 2px.
- Blur: 8px.
- Opacity: approximately 4%.

**Medium elevation**

- Y offset: 6px.
- Blur: 18px.
- Opacity: approximately 7%.

**High elevation**

- Y offset: 12px.
- Blur: 32px.
- Opacity: approximately 10%.

Use dark neutral shadow colors rather than purple shadows.

In dark mode, rely primarily on tonal elevation and borders.

Avoid stacking multiple heavy shadows.

---

# 6. Component Styling

Update the visual presentation of every existing component using shared tokens.

Do not change component behavior or placement.

## 6.1 Buttons

### Primary Buttons

- Filled with brandPrimary.
- White foreground text where contrast is sufficient.
- Medium font weight.
- Moderate corner radius.
- No default shadow.
- Slight tonal changes on hover and press.

### Secondary Buttons

- Neutral surface.
- Subtle border.
- Primary text.
- Minimal hover tint.

### Tertiary Buttons

- Transparent background.
- Text or icon foreground.
- Subtle hover surface.

### Destructive Buttons

- Reserved error styling.
- Avoid making destructive actions visually dominant unless confirmation is required.

Do not turn every action into a filled brand-colored button.

## 6.2 Input Fields

Use:

- Neutral background.
- Thin borders.
- Clear text contrast.
- Subtle placeholder styling.
- Visible focus state.
- Consistent internal padding.

Avoid heavy filled backgrounds and oversized outlines.

Focused inputs should use a restrained brand-colored border or focus ring.

Do not alter validation behavior.

## 6.3 Cards

Use white or neutral surfaces with subtle borders.

Avoid strong shadows unless cards are actually elevated.

Do not give every card a tinted background.

Preserve generous but controlled internal whitespace.

Use stronger typographic hierarchy rather than decorative elements.

## 6.4 Dialogs and Popovers

Use elevated neutral surfaces.

Maintain clear separation from the background.

Apply restrained shadows and softly rounded corners.

Use subtle scrim overlays.

Keep existing action placement and dismiss behavior.

## 6.5 Dropdowns and Menus

Use compact, well-spaced menu rows.

Apply a subtle background tint to hovered and selected items.

Preserve clear dividers only where groups need separation.

Avoid excessive borders between every item.

## 6.6 Tabs and Segmented Controls

Inactive states should remain neutral.

Selected states may use a soft lavender surface or understated accent indicator.

Avoid oversized capsules and overly colorful backgrounds.

Do not change tab position or navigation behavior.

## 6.7 Toggles, Checkboxes, and Sliders

Use existing control geometry and semantics.

Apply the brand accent to active states.

Ensure disabled and inactive states are distinguishable.

Preserve native interaction expectations.

## 6.8 Toolbars

Use visually quiet surfaces.

Avoid heavy tool grouping.

Distinguish active tools with soft background tint and clear selected-state contrast.

Keep toolbar icons readable at compact sizes.

Do not change toolbar arrangement or available tools.

---

# 7. Navigation Styling

Preserve the current navigation architecture.

Refresh only its styling.

## Sidebars

- Use backgroundSecondary or another subtle neutral surface.
- Maintain gentle separation from the main content area.
- Avoid thick borders.
- Use quiet inactive navigation states.
- Highlight the selected destination with a subtle brand-tinted surface.
- Keep text and icons optically balanced.

## Top Bars

- Use clean surfaces.
- Avoid unnecessary elevation.
- Apply subtle bottom borders only where helpful.
- Preserve the existing visual hierarchy.

## Bottom Navigation

- Retain current navigation items.
- Use restrained active-state emphasis.
- Avoid excessive animation and decorative indicators.

---

# 8. Notes and PDF Workspace

The Notes and PDF interface is the most important area for long-term usability.

It must remain extremely clean and comfortable.

### Requirements

- Prioritize writing and reading space.
- Keep controls visually secondary to the document.
- Avoid introducing decorative backgrounds around the canvas.
- Preserve existing annotation behavior.
- Maintain current zooming, panning, selection, and gesture interactions.
- Preserve document-specific page colors.
- Do not modify PDF rendering.
- Do not alter pen stroke rendering, ink colors, or user-created annotations.

Use warm neutral UI chrome while maintaining a clear distinction from the actual document.

The application theme must never change the appearance of stored handwritten notes without explicit user intent.

---

# 9. Study Desk and AI UI

Preserve existing Study Desk layouts and interaction flows.

Apply the same typography, colors, spacing, and surfaces as the rest of Etonia.

Do not create a separate visual identity for AI features.

### AI Chat Styling

- Neutral conversation background.
- Minimal message containers.
- Restrained brand accents.
- Clear source-reference styling.
- Comfortable spacing for long explanations.
- High readability for Markdown, mathematical notation, and code.
- Avoid large decorative gradients and glow effects.

### Practice and Flashcards

- Focus on content legibility.
- Use subtle distinction between question and answer.
- Use semantic feedback colors for correct and incorrect states.
- Maintain consistent card geometry.
- Avoid visually aggressive success or failure effects.

### Calendar

- Neutral grid lines.
- Gentle selected-date background.
- Clear event hierarchy.
- Restrained use of accent colors.

Preserve any user-defined calendar category colors.

---

# 10. Interaction and Motion Styling

Maintain existing interaction logic and animation sequences.

Only refine visual transitions where necessary to support the new theme.

Suggested motion characteristics:

- Fast controls: approximately 120–180ms.
- Standard interface transitions: approximately 180–250ms.
- Large panel transitions: approximately 240–320ms.

Use natural easing.

Avoid unnecessary bouncing, overshooting, glowing, or elaborate transitions.

Do not add new loading delays.

Respect reduced-motion accessibility settings.

Use subtle state transitions rather than dramatic animations.

---

# 11. Spacing and Visual Rhythm

Preserve the current layout and its overall density.

Introduce consistent spacing tokens for styling refinements:

4, 8, 12, 16, 20, 24, 32, 40, and 48 logical pixels.

Do not globally increase spacing without checking the consequences.

Density must remain appropriate for desktop and tablet productivity workflows.

Favor:

- Consistent component padding.
- Clear vertical hierarchy.
- Aligned baselines.
- Predictable control spacing.
- Balanced whitespace.

Avoid excessive empty space in information-dense screens.

---

# 12. Responsive Behavior

Maintain existing responsive breakpoints and device-specific layouts.

The theme must work across:

- iPhone.
- iPad.
- Android phones.
- Android tablets.
- Desktop platforms already supported by the project.

Do not rewrite responsive behavior as part of this redesign.

Ensure typography, surfaces, and interaction states are coherent across platforms.

Support touch, mouse, keyboard, and stylus interactions where currently implemented.

---

# 13. Accessibility

Maintain or improve accessibility.

Requirements:

- Target WCAG AA contrast ratios: 4.5:1 for normal text and 3:1 for large text.
- Ensure meaningful controls and state indicators achieve sufficient contrast.
- Do not use color as the only state indicator.
- Respect system text scaling.
- Preserve keyboard navigation.
- Maintain visible focus indicators.
- Respect reduced-motion preferences.
- Support light and dark mode.
- Avoid relying on subtle shadows alone to distinguish important controls.

When a proposed palette color fails contrast requirements, adjust its effective foreground/background pairing while preserving the overall visual direction.

---

# 14. Flutter Implementation Architecture

Inspect the existing theme implementation before making changes.

Reuse current architecture where practical.

Centralize design tokens using:

- `ThemeData`
- `ColorScheme`
- `TextTheme`
- `ThemeExtension`
- Existing reusable component themes

Prefer changes to shared component styles over individual screen overrides.

Avoid creating duplicate design systems.

Do not add unnecessary dependencies.

If Inter or Newsreader must be introduced, use appropriately licensed font resources and configure reliable font fallbacks.

Create semantic tokens for:

- Colors.
- Typography.
- Borders.
- Corner radii.
- Elevation.
- Component states.
- Spacing.
- Motion durations.

Do not hardcode visual properties across unrelated widgets.

Ensure light and dark themes remain synchronized.

---

# 15. Implementation Process

## Phase 1 — Audit

Inspect the existing UI architecture.

Identify:

- Current theme definitions.
- Global colors.
- Font usage.
- Shared component styling.
- Repeated hardcoded visual values.
- Inconsistent corner radii.
- Inconsistent hover and selected states.

Do not change implementation until the relevant shared styling structure has been identified.

## Phase 2 — Theme Foundation

Implement centralized light and dark theme tokens.

Configure typography and reusable style definitions.

Maintain compatibility with existing widgets and layout assumptions.

## Phase 3 — Shared Component Styling

Update existing:

- Buttons.
- Inputs.
- Cards.
- Menus.
- Dialogs.
- Toolbars.
- Navigation styling.
- Tabs.
- Other existing shared UI components.

Preserve each component's API and behavior.

## Phase 4 — Screen-Level Refinement

Apply the theme consistently across:

- Library.
- Notes.
- PDF Reader.
- Study Desk.
- AI Chat.
- Flashcards.
- Practice.
- Calendar.
- Settings.
- Subscription screens.
- Onboarding.

Make only visual changes.

## Phase 5 — Validation

Review all supported device classes and both color themes.

Check:

- Layout overflow.
- Font clipping.
- Contrast.
- Component states.
- Icon visibility.
- Text scaling.
- Alignment.
- Surface consistency.
- Existing functionality.

Use screenshot comparisons where possible.

Ensure the redesign does not introduce regressions.

---

# 16. Final Design Quality Requirements

The final interface must:

1. Feel premium and cohesive.
2. Preserve the existing Etonia user experience.
3. Maintain modern Apple-like simplicity.
4. Introduce subtle warmth through color and typography.
5. Use consistent geometry and component styling.
6. Avoid excessive decoration.
7. Remain comfortable for prolonged study sessions.
8. Work consistently in light and dark modes.
9. Preserve all existing features and interactions.
10. Have a recognizable design language independent of any single illustration or logo.

**Final visual target:**

A refined digital study workspace combining Apple's disciplined interface design, the warmth of premium stationery, and the subtle character of contemporary editorial design.

It should look professionally crafted, approachable, timeless, and distinctly Etonia.

Do not rebuild the application.

Do not redesign its information architecture.

Do not replace its icons.

**Redesign the visual system, not the product.**
