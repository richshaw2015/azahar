import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';

@Component
export struct GlobalWallpaper {
  @StorageLink('globalWallpaperUri') @Watch('reloadWallpaper') wallpaperUri: string = '';
  @StorageLink('globalWallpaperVersion') @Watch('reloadWallpaper') wallpaperVersion: number = 0;
  @State private wallpaperPixelMap: image.PixelMap | undefined = undefined;

  private loadToken: number = 0;

  aboutToAppear(): void {
    this.reloadWallpaper();
  }

  aboutToDisappear(): void {
    this.loadToken++;
    this.replacePixelMap(undefined);
  }

  private reloadWallpaper(): void {
    const token = ++this.loadToken;
    const path = this.getPathFromUri(this.wallpaperUri);
    if (!path) {
      this.replacePixelMap(undefined);
      return;
    }
    this.loadPixelMap(path, token);
  }

  private async loadPixelMap(path: string, token: number): Promise<void> {
    let source: image.ImageSource | undefined = undefined;
    try {
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const stat = fileIo.statSync(file.fd);
        const buffer = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buffer);
        source = image.createImageSource(buffer);
        const pixelMap = await source.createPixelMap();
        if (token !== this.loadToken) {
          pixelMap.release();
          return;
        }
        this.replacePixelMap(pixelMap);
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_error) {
      this.replacePixelMap(undefined);
    } finally {
      source?.release();
    }
  }

  private replacePixelMap(pixelMap: image.PixelMap | undefined): void {
    const old = this.wallpaperPixelMap;
    this.wallpaperPixelMap = pixelMap;
    old?.release();
  }

  private getPathFromUri(uri: string): string {
    if (!uri.startsWith('file://')) {
      return '';
    }
    const path = uri.substring('file://'.length);
    const queryIndex = path.indexOf('?');
    return queryIndex >= 0 ? path.substring(0, queryIndex) : path;
  }

  build() {
    if (this.wallpaperPixelMap) {
      Stack({ alignContent: Alignment.TopStart }) {
        Image(this.wallpaperPixelMap)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .interpolation(ImageInterpolation.High)

        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.wallpaper_scrim'))

        Column()
          .width('100%')
          .height('30%')
          .linearGradient({
            angle: 180,
            colors: [[$r('app.color.wallpaper_fade_soft'), 0.0], [$r('app.color.wallpaper_fade_clear'), 1.0]]
          })

        Column()
          .width('100%')
          .height('34%')
          .linearGradient({
            angle: 180,
            colors: [[$r('app.color.wallpaper_fade_clear'), 0.0], [$r('app.color.wallpaper_fade_strong'), 1.0]]
          })
          .position({ x: 0, y: '100%' })
          .markAnchor({ x: 0, y: '100%' })
      }
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .hitTestBehavior(HitTestMode.None)
    }
  }
}
