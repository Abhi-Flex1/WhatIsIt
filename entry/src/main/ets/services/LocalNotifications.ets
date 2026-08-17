/**
 * LocalNotifications — the shell's OWN notification feature.
 *
 * Polls the webview DOM for unread/new messages and fires a NATIVE local
 * notification (Notifications Kit) with a badge update. This is not
 * WhatsApp's push (there's no web push channel) — it's the shell detecting
 * DOM changes and alerting locally. Only works while the webview is alive
 * and the poller is running.
 *
 * Also exposes postAlert() for the shell's own alerts (Jitsi call invites,
 * re-link reminders) over the same local notification channel.
 */
import { cdpBridge } from './CdpBridge';
import { AppLifecycle } from './AppLifecycle';
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'LocalNotifications';
const DOMAIN = 0x0000;
const POLL_MS = 10000;

export class LocalNotifications {
  private timer: number | null = null;
  private lastUnreadTotal: number = 0;
  private context: common.UIAbilityContext | null = null;

  /** Set the UI context once (needed for requestEnableNotification). */
  init(context: common.UIAbilityContext): void {
    if (this.context === null) {
      this.context = context;
    }
  }

  start(): void {
    this.stop();
    this.timer = setInterval(() => {
      if (!AppLifecycle.isForeground()) {
        return;
      }
      cdpBridge.getUnreadTotal().then((total: number) => {
        if (total > this.lastUnreadTotal && this.lastUnreadTotal > 0) {
          // Show the real sender + preview from the live chat list.
          cdpBridge.getLatestUnreadChat().then((chat) => {
            if (chat !== null) {
              const sender = chat.name.length > 0 ? chat.name : 'WhatsApp';
              const body = chat.preview.length > 0 ? chat.preview : 'You have ' + total + ' unread messages.';
              this.post(sender, body);
            } else {
              this.post('New messages', 'You have ' + total + ' unread messages in WhatIsIt.');
            }
          }).catch(() => {
            this.post('New messages', 'You have ' + total + ' unread messages in WhatIsIt.');
          });
        }
        this.lastUnreadTotal = total;
        // Keep the app-icon badge in sync.
        this.setBadge(total);
      }).catch(() => {
        // ignore transient poll errors
      });
    }, POLL_MS);
  }

  stop(): void {
    if (this.timer !== null) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  /** Publish a native notification via Notifications Kit. */
  async post(title: string, text: string): Promise<void> {
    if (this.context === null) {
      hilog.warn(DOMAIN, TAG, 'post: no context');
      return;
    }
    try {
      const request: notificationManager.NotificationRequest = {
        id: Date.now() % 100000,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text,
          },
        },
      };
      await notificationManager.publish(request);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'post failed: %{public}s', JSON.stringify(err));
    }
  }

  /** Update the app-icon notification badge (0 clears). */
  async setBadge(count: number): Promise<void> {
    try {
      await notificationManager.setBadgeNumber(count);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setBadge failed: %{public}s', JSON.stringify(err));
    }
  }

  /** Request the notification permission (user prompt) — call once at startup. */
  async requestPermission(): Promise<void> {
    if (this.context === null) {
      return;
    }
    try {
      await notificationManager.requestEnableNotification(this.context);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'requestEnableNotification failed: %{public}s', JSON.stringify(err));
    }
  }

  /** Clear the badge (e.g. when the user opens the app). */
  async clearBadge(): Promise<void> {
    await this.setBadge(0);
  }
}

/** Singleton export. */
export const localNotifications = new LocalNotifications();
