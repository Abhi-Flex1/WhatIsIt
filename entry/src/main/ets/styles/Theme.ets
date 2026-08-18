/**
 * Theme — HarmonyOS design tokens for WhatIsIt.
 *
 * The palette follows the HarmonyOS / OpenHarmony design system: the
 * emphasise blue (#007DFF light / #006CDE dark), #F1F3F5 page background,
 * #FFFFFF cards, #182431 ink at 100% / 60% / 40% / 20% opacities, and
 * #33FFFFFF / #33182431 dividers. Canvas, surface and ink colors live in
 * resources/base|dark/element/color.json so components resolve them with
 * $r('app.color.*') and adapt to light/dark automatically. Type scale,
 * 4pt spacing, radius and motion follow the HarmonyOS design system.
 */
export class Theme {
  // Brand / accent (HarmonyOS emphasise blue)
  static readonly ACCENT: string = '#007DFF';
  static readonly ACCENT_PRESSED: string = '#0066CC';
  static readonly ACCENT_SOFT: string = '#E7F0FF';

  // Status / ticks
  static readonly READ: string = '#007DFF';            // blue read ticks
  static readonly DELIVERED: string = '#9AA5B5';       // grey delivered ticks
  static readonly READ_OUT: string = '#FFFFFF';        // ticks on the blue bubble
  static readonly DELIVERED_OUT: string = '#C7E2FF';
  static readonly CALL_BG: string = '#1F2C34';

  // Type scale (HarmonyOS: Headline / Title / Subhead / Body / Caption / Overline)
  static readonly TYPE_LARGE_TITLE: number = 24;       // page headline (Medium)
  static readonly TYPE_TITLE: number = 20;
  static readonly TYPE_SUBHEAD: number = 17;
  static readonly TYPE_BODY: number = 16;
  static readonly TYPE_CAPTION: number = 12;
  static readonly TYPE_OVERLINE: number = 10;

  // Spacing rhythm (4pt)
  static readonly SPACE_1: number = 4;
  static readonly SPACE_2: number = 8;
  static readonly SPACE_3: number = 12;
  static readonly SPACE_4: number = 16;
  static readonly SPACE_5: number = 24;

  // Radii
  static readonly RADIUS_CARD: number = 16;
  static readonly RADIUS_CHIP: number = 18;
  static readonly RADIUS_PILL: number = 22;
  static readonly RADIUS_BUBBLE: number = 16;
  static readonly RADIUS_FIELD: number = 22;

  // Avatars / layout sizes
  static readonly AVATAR_SIZE: number = 48;
  static readonly ROW_HEIGHT: number = 72;
  static readonly HEADER_HEIGHT: number = 56;
  static readonly TAB_BAR_HEIGHT: number = 60;
  static readonly FAB_SIZE: number = 56;

  // Motion (HarmonyOS springMotion: stiffness/damping)
  static readonly SPRING_DEFAULT: string = '0.35, 0.85';
  static readonly DURATION_FAST: number = 200;
  static readonly DURATION_BASE: number = 260;
  static readonly DURATION_SLOW: number = 320;

  // HarmonyOS palette — colourful contact avatars like the Messages app.
  static readonly PALETTE: string[] = [
    '#3F56EA', '#00AAEE', '#00BFC9', '#47CC47', '#8CD600',
    '#8A2BE2', '#E40078', '#FA2A2D', '#FF7500', '#FF9800', '#FFBF00'
  ];

  /** Deterministic palette color for a contact/chat, e.g. Theme.avatarColor(id). */
  static avatarColor(key: string): string {
    if (key.length === 0) {
      return Theme.PALETTE[0];
    }
    let h = 0;
    for (let i = 0; i < key.length; i++) {
      h = (h * 31 + key.charCodeAt(i)) >>> 0;
    }
    return Theme.PALETTE[h % Theme.PALETTE.length];
  }
}