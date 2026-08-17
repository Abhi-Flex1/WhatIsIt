/**
 * AppLifecycle — tracks whether the app is in the foreground.
 *
 * MainPage sets this via onPageShow / onPageHide. Polling services (chats,
 * messages, calls, keep-alive) check it so they pause when backgrounded —
 * the biggest app-side battery win.
 */
export class AppLifecycle {
  private static foreground: boolean = true;

  static setForeground(v: boolean): void {
    AppLifecycle.foreground = v;
  }

  static isForeground(): boolean {
    return AppLifecycle.foreground;
  }
}
