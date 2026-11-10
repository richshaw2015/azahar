const STORAGE_KEY: string = 'floatTilesPageScrolling';
const RESUME_DELAY_MS: number = 500;
let nextSourceId: number = 1;
let activeSources: number[] = [];
let resumeTimer: number = 0;

AppStorage.setOrCreate(STORAGE_KEY, false);

function cancelPendingResume(): void {
  if (resumeTimer !== 0) {
    clearTimeout(resumeTimer);
    resumeTimer = 0;
  }
}

export function createScrollSource(): number {
  return nextSourceId++;
}

export function setScrollSourceActive(sourceId: number, isActive: boolean): void {
  const index = activeSources.indexOf(sourceId);
  if (isActive) {
    cancelPendingResume();
    if (index < 0) {
      activeSources.push(sourceId);
    }
    AppStorage.setOrCreate(STORAGE_KEY, true);
    return;
  }

  if (index >= 0) {
    activeSources.splice(index, 1);
  }
  if (activeSources.length > 0) {
    AppStorage.setOrCreate(STORAGE_KEY, true);
    return;
  }
  if (index < 0 || resumeTimer !== 0) {
    return;
  }

  resumeTimer = setTimeout(() => {
    resumeTimer = 0;
    if (activeSources.length === 0) {
      AppStorage.setOrCreate(STORAGE_KEY, false);
    }
  }, RESUME_DELAY_MS);
}
