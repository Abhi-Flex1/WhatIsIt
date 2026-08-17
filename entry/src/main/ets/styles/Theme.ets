/**
 * Theme — HarmonyOS Design tokens for WhatIsIt.
 *
 * Central color / typography / spacing / radius scale per the HarmonyOS
 * design guidelines (semantic neutrals, WhatsApp-green accent, type scale,
 * 4pt spacing rhythm, 12px corner radius cards).
 */
export class Theme {
  // Brand / accent
  static readonly ACCENT: string = '#00A884';          // WhatsApp green
  static readonly ACCENT_PRESSED: string = '#008A6B';
  static readonly ACCENT_SOFT: string = '#E7FCE3';     // green tint surface

  // Semantic neutrals (HarmonyOS-ish canvas/surface/ink)
  static readonly CANVAS: string = '#F1F3F5';          // app background
  static readonly SURFACE: string = '#FFFFFF';         // cards / list items
  static readonly SURFACE_SUBTLE: string = '#F5F6F7';  // pressed / chips
  static readonly INK: string = '#182431';             // primary text
  static readonly INK_SUBTLE: string = '#5F6B7A';      // secondary text
  static readonly INK_FADED: string = '#8A94A6';       // tertiary / timestamps

  // Status / states
  static readonly READ: string = '#53BDEB';            // light blue (read ticks)
  static readonly DELIVERED: string = '#9AA5B5';       // grey (delivered ticks)
  static readonly DANGER: string = '#E84026';
  static readonly SUCCESS: string = '#00A884';
  static readonly CALL_BG: string = '#1F2C34';

  // Type scale (HarmonyOS design: Large title / Title / Body / Caption)
  static readonly TYPE_LARGE_TITLE: number = 28;
  static readonly TYPE_TITLE: number = 22;
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

  // Radii (HarmonyOS 12px card corners)
  static readonly RADIUS_CARD: number = 12;
  static readonly RADIUS_CHIP: number = 16;
  static readonly RADIUS_PILL: number = 22;
}
