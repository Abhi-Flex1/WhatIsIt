/**
 * MediaSender — the native-capture half of the media bridge.
 *
 * Uses the system pickers (gallery / camera) to let the user choose media
 * natively, then hands the picked file to CdpBridge.sendMediaFiles(), which
 * injects it into the page's own composer file input over CDP. The page
 * uploads; the shell stays fully native.
 */
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { camera, cameraPicker } from '@kit.CameraKit';
import { cdpBridge } from './CdpBridge';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';

const TAG = 'MediaSender';
const DOMAIN = 0x0000;

export type MediaSendMode = 'gallery' | 'camera';

export class MediaSender {
  /**
   * Pick a photo/video natively and send it into the open chat via CDP.
   * Returns true if the page accepted the file (upload initiated).
   */
  async pickAndSend(context: common.UIAbilityContext, mode: MediaSendMode): Promise<boolean> {
    let path = '';
    if (mode === 'gallery') {
      path = await this.pickFromGallery(context);
    } else {
      path = await this.pickFromCamera(context);
    }
    if (path.length === 0) {
      hilog.info(DOMAIN, TAG, 'pickAndSend: no file picked');
      return false;
    }
    return cdpBridge.sendMediaFiles([path]);
  }

  private async pickFromGallery(context: common.UIAbilityContext): Promise<string> {
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const picker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.maxSelectNumber = 1;
      const result = await picker.select(options);
      const uris = result.photoUris;
      if (uris === undefined || uris.length === 0) {
        return '';
      }
      return uris[0];
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'gallery pick failed: %{public}s', JSON.stringify(err));
      return '';
    }
  }

  private async pickFromCamera(context: common.UIAbilityContext): Promise<string> {
    try {
      const profile = new cameraPicker.PickerProfile();
      profile.cameraPosition = camera.CameraPosition.CAMERA_POSITION_BACK;
      const result = await cameraPicker.pick(context, [cameraPicker.PickerMediaType.PHOTO], profile);
      return result.resultUri;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'camera pick failed: %{public}s', JSON.stringify(err));
      return '';
    }
  }
}

/** Singleton export. */
export const mediaSender = new MediaSender();
