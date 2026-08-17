/**
 * ServerConfig — hidden background configuration.
 *
 * No user-facing plumbing: the backend endpoint is baked in here
 * (compile-time constant), never exposed in the UI. This matches the product
 * rule that server/endpoint configuration lives entirely in background code.
 */
export class ServerConfig {
  /**
   * The host running the whatisit-adapter.
   * '127.0.0.1' = a local dev server on the same machine (default for emulator).
   * A production domain = the public backend in cloud infra.
   */
  static readonly BACKEND_HOST: string = '127.0.0.1';

  /** The backend HTTP/WS port (adapter). */
  static readonly BACKEND_PORT: number = 18770;

  /** Bearer token for the backend (empty = no auth). Hidden, compile-time. */
  static readonly BACKEND_TOKEN: string = '';

  /** Preference key for the hidden persisted host override. */
  static readonly BACKEND_HOST_PREF: string = 'backend_host';

  /** Preference key for the hidden persisted token override. */
  static readonly BACKEND_TOKEN_PREF: string = 'backend_token';

  /** Fallback hosts tried during auto-discovery if the primary host fails. */
  static readonly BACKEND_FALLBACKS: string[] = [
    '127.0.0.1',
    'localhost',
  ];

  /** If true, the app auto-discovers the backend by probing known hosts. */
  static readonly AUTO_DISCOVER: boolean = true;

  /** Deep-link scheme for provisioning QR codes. */
  static readonly PROVISION_SCHEME: string = 'whatisit';

  /** Deep-link host for provisioning. */
  static readonly PROVISION_HOST: string = 'provision';
}
