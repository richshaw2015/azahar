import { image } from '@kit.ImageKit';
import { GameInfo } from '../utils/GameManager';

@Observed
export class AzaharGameCardModel {
  gameInfo: GameInfo;
  displayName: string;
  subtitle: string;
  gameIcon: image.PixelMap | undefined = undefined;
  coverImage: image.PixelMap | undefined = undefined;
  coverColor: string = '';

  constructor(gameInfo: GameInfo, displayName: string, subtitle: string, gameIcon?: image.PixelMap) {
    this.gameInfo = gameInfo;
    this.displayName = displayName;
    this.subtitle = subtitle;
    this.gameIcon = gameIcon;
  }

  updateDisplay(displayName: string, subtitle: string): void {
    this.displayName = displayName;
    this.subtitle = subtitle;
  }
}
