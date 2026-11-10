import { AzaharGameCardModel } from './AzaharGameCardModel';

export class AzaharGameCardDataSource implements IDataSource {
  private items: AzaharGameCardModel[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): AzaharGameCardModel {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  reloadAll(items: AzaharGameCardModel[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  notifyItemChange(index: number): void {
    for (const listener of this.listeners) {
      listener.onDataChange(index);
    }
  }

  size(): number {
    return this.items.length;
  }

  forEach(callback: (item: AzaharGameCardModel, index: number) => void): void {
    this.items.forEach(callback);
  }

  findByPath(path: string): AzaharGameCardModel | undefined {
    return this.items.find((item: AzaharGameCardModel) => item.gameInfo.path === path);
  }

  indexOfPath(path: string): number {
    return this.items.findIndex((item: AzaharGameCardModel) => item.gameInfo.path === path);
  }
}
