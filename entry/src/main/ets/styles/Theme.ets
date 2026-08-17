/**
 * Theme — HarmonyOS design tokens for WhatIsIt.
 *
 * Brand / status colors are theme-invariant constants. Canvas, surface and
 * ink colors live in resources/base|dark/element/color.json so components
 * resolve them with $r('app.color.*') and adapt to light/dark automatically.
 * Type scale, 4pt spacing, radius and motion follow the HarmonyOS design
 * system (with iOS-WhatsApp-informed component layout).
 */
export class Theme {
  // Brand / accent (WhatsApp green, identical in light & dark)
  static readonly ACCENT: string = '#00A884';
  static readonly ACCENT_PRESSED: string = '#008A6B';
  static readonly ACCENT_SOFT: string = '#E7FCE3';

  // Status / ticks
  static readonly READ: string = '#53BDEB';            // light blue (read ticks)
  static readonly DELIVERED: string = '#9AA5B5';       // grey (delivered ticks)
  static readonly CALL_BG: string = '#1F2C34';

  // Type scale (HarmonyOS: Large title / Title / Subhead / Body / Caption / Overline)
  static readonly TYPE_LARGE_TITLE: number = 34;       // iOS-style large nav title
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
  static readonly RADIUS_CARD: number = 12;
  static readonly RADIUS_CHIP: number = 16;
  static readonly RADIUS_PILL: number = 22;
  static readonly RADIUS_BUBBLE: number = 14;
  static readonly RADIUS_FIELD: number = 20;

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
}