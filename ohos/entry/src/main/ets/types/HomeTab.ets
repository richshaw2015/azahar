export enum HomeTab {
  RECENT = 0,
  FAVORITES = 1,
  ALL = 2
}

export function normalizeHomeTab(value: number): HomeTab {
  if (value === HomeTab.FAVORITES) {
    return HomeTab.FAVORITES;
  }
  if (value === HomeTab.ALL) {
    return HomeTab.ALL;
  }
  return HomeTab.RECENT;
}
