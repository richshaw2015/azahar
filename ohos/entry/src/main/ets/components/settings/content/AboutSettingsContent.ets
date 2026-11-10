import { ComposeListItem, IconType, router, SymbolGlyphModifier } from '@kit.ArkUI';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { systemShare } from '@kit.ShareKit';
import { SettingsList, SettingsSectionHeader, settingsGroupDivider, menuGroupPadding } from '../SettingsList';
import { AppIconView } from '../../AppIconView';
import { TEXT_PRIMARY, TEXT_SECONDARY } from '../../../types/UIConstants';
import { AppIconManager } from '../../../utils/AppIconManager';
import { I18n } from '../../../utils/I18nManager';
import { SoundEffect, SoundEffectManager } from '../../../utils/SoundEffectManager';
import { initToastHelper, showErrorToast, showInfoToast } from '../../../utils/ToastHelper';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';
import { AzaharThemeColors } from '../../../types/ThemeTypes';

interface AboutLinks {
  privacyPolicy: string;
  userAgreement: string;
  sourceCode: string;
  contactEmail: string;
}

// 外部链接占位：先放 UI 入口，后续填入地址即可生效；留空时点击提示“暂未开放”
const ABOUT_LINKS: AboutLinks = {
  privacyPolicy: '',
  userAgreement: '',
  sourceCode: '',
  contactEmail: ''
};

const ABOUT_ICON_SIZE: number = 88;

type AboutLinkAction = 'url' | 'email' | 'share';

interface AboutLinkItem {
  icon: Resource;
  title: string;
  action: AboutLinkAction;
  value: string;
}

@Component
export struct AboutSettingsContent {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  scroller?: Scroller;
  @State private versionName: string = '';
  @State private versionCode: number = 0;

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();

  async aboutToAppear(): Promise<void> {
    initToastHelper(this.getUIContext());
    await this.soundEffectManager.initialize(this.context);
    AppIconManager.getInstance().refreshStyleProp();
    this.loadBundleInfo();
  }

  private loadBundleInfo(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.versionName = info.versionName || '';
      this.versionCode = info.versionCode || 0;
    } catch (error) {
      console.error(`[AboutSettings] load bundle info failed: ${(error as Error).message}`);
      this.versionName = '';
      this.versionCode = 0;
    }
  }

  private versionText(): string {
    const version = this.versionName || '0.0.0';
    if (this.versionCode > 0) {
      return I18n.tf2('version_build_fmt', 'version', version, 'build', this.versionCode);
    }
    return I18n.tf1('version_fmt', 'version', version);
  }

  private getLinkItems(): AboutLinkItem[] {
    return [
      {

        icon: $r('sys.symbol.checkmark_shield'),
        title: I18n.t('privacy_policy'),
        action: 'url',
        value: ABOUT_LINKS.privacyPolicy
      },
      {

        icon: $r('sys.symbol.doc'),
        title: I18n.t('user_agreement'),
        action: 'url',
        value: ABOUT_LINKS.userAgreement
      },
      {

        icon: $r('sys.symbol.code'),
        title: I18n.t('view_source'),
        action: 'url',
        value: ABOUT_LINKS.sourceCode
      },
      {

        icon: $r('sys.symbol.envelope'),
        title: I18n.t('contact_email'),
        action: 'email',
        value: ABOUT_LINKS.contactEmail
      },
      {

        icon: $r('sys.symbol.share'),
        title: I18n.t('share_app'),
        action: 'share',
        value: I18n.t('share_text')
      }
    ];
  }

  private handleLinkClick(item: AboutLinkItem): void {
    if (item.action === 'share') {
      this.shareText(item.value);
      return;
    }
    if (!item.value) {
      showInfoToast(I18n.t('about_link_coming_soon'));
      return;
    }
    if (item.action === 'url') {
      this.openUrl(item.value);
    } else {
      void this.sendEmail(item.value);
    }
  }

  private openUrl(url: string): void {
    try {
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url
      };
      this.context.startAbility(want).catch((err: Error) => {
        console.error(`[AboutSettings] open url failed: ${err.message}`);
      });
    } catch (error) {
      console.error(`[AboutSettings] open url error: ${(error as Error).message}`);
    }
  }

  private getMailtoRecipient(url: string): string {
    const recipientWithQuery = url.substring('mailto:'.length);
    const queryIndex = recipientWithQuery.indexOf('?');
    const recipient = queryIndex >= 0
      ? recipientWithQuery.substring(0, queryIndex)
      : recipientWithQuery;
    try {
      return decodeURIComponent(recipient).trim();
    } catch (error) {
      console.warn(`[AboutSettings] decode mailto recipient failed: ${(error as Error).message}`);
      return recipient.trim();
    }
  }

  // 没有可用邮件应用或拉起失败时，把收件人地址复制到剪贴板兜底
  private copyMailtoRecipient(url: string, reason: string): void {
    const recipient = this.getMailtoRecipient(url);
    if (!recipient) {
      console.error(`[AboutSettings] empty mailto recipient, skip copy: ${reason}`);
      return;
    }
    try {
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, recipient);
      pasteboard.getSystemPasteboard().setData(pasteData).then(() => {
        this.soundEffectManager.play(SoundEffect.CONFIRM);
        showInfoToast(I18n.t('contact_email_copied'), 3000);
      }).catch((err: Error) => {
        console.error(`[AboutSettings] copy email failed: ${err.message}`);
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(I18n.t('contact_email_copy_failed'));
      });
    } catch (error) {
      console.error(`[AboutSettings] copy email error: ${(error as Error).message}`);
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('contact_email_copy_failed'));
    }
  }

  private async sendEmail(email: string): Promise<void> {
    const url = `mailto:${email}`;
    let canOpenMailto = false;
    try {
      // canOpenLink 要求 URI 含 "://"；真正拉起仍用 RFC mailto 地址
      canOpenMailto = bundleManager.canOpenLink('mailto://');
    } catch (error) {
      console.warn(`[AboutSettings] query mailto support failed: ${(error as Error).message}`);
    }
    if (!canOpenMailto) {
      this.copyMailtoRecipient(url, 'mailto is not supported');
      return;
    }
    const want: Want = {
      action: 'ohos.want.action.sendToData',
      uri: url
    };
    try {
      await this.context.startAbility(want);
    } catch (error) {
      console.warn(`[AboutSettings] open mail app failed: ${(error as Error).message}`);
      this.copyMailtoRecipient(url, 'mail app launch failed');
    }
  }

  private shareText(text: string): void {
    try {
      const shareData: systemShare.SharedData = new systemShare.SharedData({
        utd: 'general.plain-text',
        content: text
      });
      const shareController: systemShare.ShareController = new systemShare.ShareController(shareData);
      shareController.show(this.context, {
        previewMode: systemShare.SharePreviewMode.DETAIL,
        selectionMode: systemShare.SelectionMode.SINGLE
      }).catch((err: Error) => {
        console.error(`[AboutSettings] share failed: ${err.message}`);
      });
    } catch (error) {
      console.error(`[AboutSettings] share error: ${(error as Error).message}`);
    }
  }

  private navigateToSystemInfo(): void {
    router.pushUrl({ url: 'pages/settings/SystemInfoSettings' }).catch((error: Error) => {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('open_system_info_failed_fmt', 'error', error.message));
    });
  }

  @Builder
  SectionHeader(title: string) {
    SettingsSectionHeader({ title })
  }

  @Builder
  ActionRow(title: string, icon: Resource, onClick: () => void) {
    ComposeListItem({
      contentItem: {
        iconStyle: IconType.SYSTEM_ICON,
        icon: icon,
        symbolStyle: new SymbolGlyphModifier(icon),
        primaryText: title
      },
      operateItem: {
        arrow: {
          value: $r('sys.symbol.chevron_right')
        }
      }
    })
    .onFocus(() => {
      this.soundEffectManager.play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      this.soundEffectManager.play(SoundEffect.DECIDE);
      onClick();
    })
  }

  build() {
    SettingsList({ scroller: this.scroller }) {
      ListItem() {
        Column({ space: $r('sys.float.ohos_id_text_paragraph_margin_xs') }) {
          AppIconView({ iconSize: ABOUT_ICON_SIZE })

          Text($r('app.string.app_name'))
            .fontSize($r('sys.float.ohos_id_text_size_headline8'))
            .fontWeight(FontWeight.Bold)
            .fontColor(TEXT_PRIMARY)
            .margin({ top: $r('sys.float.ohos_id_card_margin_middle') })

          Text(this.versionText())
            .fontSize($r('sys.float.ohos_id_text_size_body2'))
            .fontColor(TEXT_SECONDARY)

          Text(I18n.t('based_on_azahar'))
            .fontSize($r('sys.float.ohos_id_text_size_body2'))
            .fontColor(TEXT_SECONDARY)
            .margin({ top: $r('sys.float.ohos_id_text_paragraph_margin_xs') })

          Text(I18n.t('adapted_harmonyos'))
            .fontSize($r('sys.float.ohos_id_text_size_body2'))
            .fontColor(TEXT_SECONDARY)
        }
        .width('100%')
        .padding({ top: $r('sys.float.ohos_id_card_margin_middle'), bottom: $r('sys.float.ohos_id_card_margin_middle') })
        .alignItems(HorizontalAlign.Center)
      }

      ListItem() {
        this.SectionHeader(I18n.t('sysinfo_section_title'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          this.ActionRow(I18n.t('system_info'), $r('sys.symbol.info_circle'), () => {
            this.navigateToSystemInfo();
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))

      ListItem() {
        this.SectionHeader(I18n.t('links_services'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ForEach(this.getLinkItems(), (item: AboutLinkItem) => {
          ListItem() {
            this.ActionRow(item.title, item.icon, () => {
              this.handleLinkClick(item);
            })
          }
        }, (item: AboutLinkItem) => item.title)
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())

      ListItem() {
        Column({ space: $r('sys.float.ohos_id_text_paragraph_margin_xs') }) {
          Text('Azahar © Azahar Emulator Project')
            .fontSize($r('sys.float.ohos_id_text_size_body2'))
            .fontColor(TEXT_SECONDARY)
          Text('Citra © Citra Emulator Project')
            .fontSize($r('sys.float.ohos_id_text_size_body2'))
            .fontColor(TEXT_SECONDARY)
          Text(I18n.t('gpl_notice'))
            .fontSize($r('sys.float.ohos_id_text_size_body2'))
            .fontColor(TEXT_SECONDARY)
            .margin({ top: $r('sys.float.ohos_id_text_paragraph_margin_xs') })
        }
        .width('100%')
        .padding({ top: $r('sys.float.ohos_id_card_margin_middle'), bottom: $r('sys.float.ohos_id_card_margin_middle') })
        .alignItems(HorizontalAlign.Center)
      }
    }
  }
}
