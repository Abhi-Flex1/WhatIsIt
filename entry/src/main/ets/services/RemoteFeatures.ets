/**
 * RemoteFeatures — native shell features that relay to WhatsApp Web via CDP.
 *
 * The native shell is the controller; Chrome/Edge (the webview engine) is the
 * display. These features call the real page's own controls over CDP — the
 * native API powers the button, the page does the WhatsApp work.
 */
import { cdpBridge } from './CdpBridge';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';

const TAG = 'RemoteFeatures';
const DOMAIN = 0x0000;

export class RemoteFeatures {
  /** Toggle the page's mute button (the page's own call media control). */
  async toggleMute(): Promise<boolean> {
    return cdpBridge.toggleMute();
  }

  /** Toggle the page's camera (video call) control. */
  async toggleCamera(): Promise<boolean> {
    return cdpBridge.toggleCamera();
  }

  /** Start a voice call in the open chat (page's own call button). */
  async startCall(): Promise<boolean> {
    return cdpBridge.startCall();
  }

  /** Start a video call in the open chat (page's own video-call button). */
  async startVideoCall(): Promise<boolean> {
    return cdpBridge.startVideoCall();
  }

  /** Accept an incoming call (page's own accept button). */
  async acceptCall(): Promise<boolean> {
    return cdpBridge.acceptCall();
  }

  /** End / reject the current call. */
  async endCall(): Promise<boolean> {
    return cdpBridge.endCall();
  }

  /** Get the current call state from the page. */
  async getCallState(): Promise<string> {
    return cdpBridge.getCallState();
  }

  /**
   * Share a location as text into the open chat's composer. This is the
   * "your feature, their page" model: the native location UI produces a
   * string, and the page's own composer sends it. Not a native location
   * bubble — a text message with the place.
   */
  async shareLocationAsText(placeName: string, lat: number, lng: number): Promise<boolean> {
    const mapsUrl = 'https://maps.google.com/?q=' + lat + ',' + lng;
    const text = placeName + '\n' + mapsUrl;
    return cdpBridge.sendMessage(text);
  }

  /**
   * Resolve the current GPS fix and share it into the open chat as a
   * maps-link text message. Handles the runtime location permission
   * request itself — the caller passes its UI context so the system
   * permission dialog can be shown.
   */
  async shareCurrentLocation(context: common.UIAbilityContext, chatName: string): Promise<boolean> {
    if (!(await this.ensureLocationPermission(context))) {
      hilog.warn(DOMAIN, TAG, 'shareCurrentLocation: location permission denied');
      return false;
    }
    try {
      if (!geoLocationManager.isLocationEnabled()) {
        hilog.warn(DOMAIN, TAG, 'shareCurrentLocation: location service disabled');
        return false;
      }
      const loc = await geoLocationManager.getCurrentLocation();
      const lat = loc.latitude;
      const lng = loc.longitude;
      hilog.info(DOMAIN, TAG, 'got fix %.6f, %.6f for %{public}s', lat, lng, chatName);
      return this.shareLocationAsText(chatName + ' (location)', lat, lng);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'shareCurrentLocation failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  private async ensureLocationPermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const grant = await atManager.checkAccessToken(context.applicationInfo.accessTokenId,
        'ohos.permission.LOCATION' as Permissions);
      if (grant === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return true;
      }
      const result = await atManager.requestPermissionsFromUser(context,
        ['ohos.permission.APPROXIMATELY_LOCATION', 'ohos.permission.LOCATION'] as Permissions[]);
      const authResult = result.authResults;
      if (authResult !== undefined && authResult.length > 0 && authResult[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return true;
      }
      return false;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'ensureLocationPermission failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }
}

/** Singleton export. */
export const remoteFeatures = new RemoteFeatures();
